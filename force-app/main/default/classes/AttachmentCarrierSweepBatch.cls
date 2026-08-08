/**
 * The RETRY / REPLAY engine for inbound broker-email attachment carriers, and the reason the
 * carrier is TEMPORARY rather than permanent.
 *
 * ═══ WHY THIS IS A DESIGNED CAPABILITY, NOT A CLEANUP AFTERTHOUGHT ═══
 * `InboundEmailAttachmentService.stageBytes` parks a broker's attachment on the staging row as a
 * classic `Attachment`. That carrier is what makes a downstream failure LOSS-FREE: if the quota
 * is exhausted, if the heap gate defers a file, or if the file job dies outright, THE BYTES ARE
 * STILL THERE. But "still there" is only a virtue if something eventually converts them — an
 * un-retried carrier is just an accumulating pile of bytes on an audit object, and this module
 * would quietly become the org's file-storage strategy.
 *
 * So a carrier row has EXACTLY FOUR EXITS, and this class owns two of them:
 *
 *   CONVERTED  AttachmentPersistQueueable deletes it, only on confirmed success
 *   RELEASED   ExtractAddressQueueable, on a gated email or a duplicate delivery
 *   RETRIED    ← THIS CLASS, daily
 *   EXPIRED    ← THIS CLASS, at CARRIER_MAX_AGE_DAYS
 *
 * 🔴 **A DEPLOY THAT DOES NOT SCHEDULE `AttachmentCarrierSweepSchedule` SILENTLY DISABLES EVERY
 * RETRY IN THIS DESIGN** — and scheduled-job instances are not deployable metadata, so it is a
 * verified post-deploy gate, not a note. See design §10.2 A5 / §13 step 6.
 *
 * ═══ 🔴 `SCOPE = 1` IS LOAD-BEARING. DO NOT RAISE IT. ═══
 * One staging row per `execute()` means one staging row per TRANSACTION, and therefore its own
 * fresh 12 MB async heap budget. That is precisely what keeps `AttachmentPersistQueueable`'s
 * §6.2 heap gate valid UNCHANGED when its code path is replayed here: the gate's arithmetic
 * (peak ~ 2 x converted bytes, `CONVERT_MAX_TOTAL_BYTES` = 4,000,000 -> 8 MB of 12 MB) assumes
 * it owns the transaction. At scope 2 a pair of 4 MB carriers would blow it, and an Apex heap
 * `LimitException` is UNCATCHABLE. The batch is deliberately slow and safe.
 *
 * ═══ IT REPLAYS THE IDENTICAL CODE PATH ═══
 * `AttachmentPersistQueueable.convert(...)` is called directly rather than reimplemented, so the
 * heap gate, the budget cap, the breaker, the `ShareType` split and the "delete only what
 * converted" rule cannot drift between the live job and its retry. Its per-`execute()` budget is
 * therefore identical: 3 SOQL / 6 DML, constant in file count and target count.
 *
 * ═══ IDEMPOTENT AND CONVERGENT BY CONSTRUCTION ═══
 * The work queue is `Attachment_Status__c IN ('Pending','Partial','Failed')` — the three values
 * that mean "work remains". A successful pass moves the status to 'Saved', which REMOVES the row
 * from the queue, so re-running the sweep is free and a second immediate pass writes nothing.
 * It also honours the breaker and the daily budget exactly as the live job does, so a sweep
 * during an exhausted window DEFERS rather than hammers.
 *
 * ⚠ ONE ROW SHAPE IS DELIBERATELY SKIPPED: a row whose ROUTING has not finished
 * (`Status__c = 'Pending'`). Converting then would create files with no routed record to link
 * them to, and stamping 'Saved' would prevent the links from ever being made. Such a row is left
 * alone on each pass and takes the EXPIRED exit if routing never completes — a defined exit, not
 * an accumulation.
 *
 * ═══ LAYER ═══
 * Batch. It holds NO SOQL of its own — `start()` delegates to
 * `InboundEmailStagingSelector.queryCarrierSweep()` per the layering rule — and no DML of its
 * own: conversion belongs to `AttachmentPersistQueueable`, carrier deletion and the terminal
 * stamp to `InboundEmailAttachmentService` / `InboundEmailStagingService`.
 *
 * @see AttachmentPersistQueueable.convert (the one code path this replays)
 * @see AttachmentCarrierSweepSchedule.cls (the daily trigger — schedule it or retry is dead)
 * @see agent-output/design-requirements-attachment-persistence-v2.md §6.4, §11.4
 */
public with sharing class AttachmentCarrierSweepBatch
        implements Database.Batchable<SObject>, Database.Stateful {

    /**
     * How long a carrier may live unconverted before it is deleted and the row stamped
     * 'Expired'. **14 days**, chosen because it is longer than any quota window (24 h) or
     * plausible outage — so a genuine transient failure always gets many retries — and short
     * enough that carriers cannot silently become permanent storage.
     */
    @TestVisible private static final Integer CARRIER_MAX_AGE_DAYS = 14;

    /** 🔴 ONE staging row per transaction. See the class header — do not raise it. */
    public static final Integer SCOPE = 1;

    /**
     * The routing status that means "the routing tree has not finished with this row yet".
     * Declared locally rather than reaching into `InboundEmailStagingService`'s private
     * `STATUS_PENDING`, and deliberately NOT conflated with `ATTACHMENT_STATUS_PENDING`, which is
     * a different state machine on a different field that happens to share a label.
     */
    private static final String ROUTING_STATUS_PENDING = 'Pending';

    /** §7 copy for the EXPIRED exit — TERMINAL, so it names where the file still exists. */
    @TestVisible private static final String NOTE_EXPIRED =
        'NOT SAVED: the carrier expired after CARRIER_MAX_AGE_DAYS (14) without a successful '
        + 'conversion. The file exists only in the original email.';

    /** Cross-chunk counters (why this is `Database.Stateful`), summarised by finish(). */
    private Integer retried = 0;
    private Integer expired = 0;
    private Integer skipped = 0;
    private Integer failed = 0;

    /**
     * The work queue: every staging row whose file pipeline has not reached a terminal state.
     *
     * @param ctx The batch context (unused; required by the interface).
     * @return A locator over the non-terminal rows, oldest first.
     */
    public Database.QueryLocator start(Database.BatchableContext ctx) {
        return InboundEmailStagingSelector.queryCarrierSweep();
    }

    /**
     * Retry, expire or skip ONE staging row (SCOPE = 1, so this list holds one element).
     *
     * FAIL-SOFT PER ROW: a single unconvertible row must not abort the sweep for every other
     * row, and — unlike the live file job, whose failure is reported by
     * `AttachmentPersistFinalizer` — a batch has no finalizer, so the failure is recorded here
     * or nowhere. Recording it as 'Failed' also KEEPS the row in the queue for the next pass,
     * which is the correct outcome for a transient failure.
     *
     * @param ctx   The batch context (unused).
     * @param scope The staging rows to process; SCOPE = 1.
     */
    public void execute(Database.BatchableContext ctx, List<Inbound_Email_Staging__c> scope) {
        if (scope == null || scope.isEmpty()) {
            return;
        }
        for (Inbound_Email_Staging__c row : scope) {
            if (row == null) {
                continue;
            }
            try {
                if (isExpired(row)) {
                    // The EXPIRED exit. releaseCarrier deletes the bytes and stamps a terminal
                    // status; the status is then corrected to 'Expired' so the two terminal
                    // reasons stay distinguishable in a list view.
                    InboundEmailAttachmentService.releaseCarrier(row.Id, 'expired');
                    InboundEmailStagingService.markAttachmentStatus(
                        row.Id,
                        InboundEmailStagingService.ATTACHMENT_STATUS_EXPIRED,
                        NOTE_EXPIRED);
                    expired++;
                    continue;
                }
                if (ROUTING_STATUS_PENDING.equals(row.Status__c)) {
                    // Routing has not finished. Converting now would create files with no
                    // routed record to link them to. Leave it for a later pass; the EXPIRED
                    // exit bounds how long that can go on.
                    skipped++;
                    continue;
                }
                // The RETRIED exit — the identical code path the live job runs.
                AttachmentPersistQueueable.convert(row.Id, routedTargets(row));
                retried++;
            } catch (Exception e) {
                failed++;
                System.debug(LoggingLevel.ERROR,
                    'AttachmentCarrierSweepBatch: staging ' + row.Id + ' failed: '
                    + e.getTypeName() + ' | ' + e.getMessage());
                InboundEmailStagingService.markAttachmentStatus(
                    row.Id,
                    InboundEmailStagingService.ATTACHMENT_STATUS_FAILED,
                    'not yet saved: the carrier sweep failed — ' + e.getTypeName() + ' | '
                    + e.getMessage() + '; the file is still attached to this staging row and '
                    + 'will be retried');
            }
        }
    }

    /**
     * Summarise the pass. Deliberately a debug line and nothing more: the durable record of
     * every outcome already lives on each staging row's own `Attachment_Status__c` and
     * `Dropped_Attachment_Notes__c`, which is queryable — unlike a static or a log.
     *
     * @param ctx The batch context (unused).
     */
    public void finish(Database.BatchableContext ctx) {
        System.debug(LoggingLevel.INFO,
            'AttachmentCarrierSweepBatch finished: retried=' + retried + ' expired=' + expired
            + ' skipped=' + skipped + ' failed=' + failed);
    }

    /**
     * Whether this row's carrier has outlived `CARRIER_MAX_AGE_DAYS`.
     *
     * Age is measured from the STAGING ROW's CreatedDate rather than the carrier's, because the
     * staging row is created first and in the same transaction — so the two are within
     * milliseconds of each other — and reading it costs no extra query.
     *
     * @param row The staging row.
     * @return true when the carrier should be expired rather than retried.
     */
    private static Boolean isExpired(Inbound_Email_Staging__c row) {
        return row.CreatedDate != null
            && row.CreatedDate < Datetime.now().addDays(-CARRIER_MAX_AGE_DAYS);
    }

    /**
     * The records this email was routed to, recovered from the staging row rather than
     * re-derived. `Routed_Record_Ids__c` holds one `address | outcome | recordId` line per
     * routed property (the ONLY place the full N-result mapping exists);
     * `Result_Record_Id__c` holds the single PRIMARY record and is the fallback for rows written
     * before that audit field carried anything.
     *
     * ⚠ RE-RUNNING THE ROUTING TREE TO REDERIVE THESE IS NOT AN OPTION — it would mean a second
     * LLM callout, a second claim attempt and a second Task, i.e. re-minting a Lead for an email
     * that already has one. The audit trail exists precisely so a replay does not have to guess.
     *
     * @param row The staging row.
     * @return The distinct routed record Ids; empty when routing produced none (a gate), in
     *         which case the files are still saved and linked to the staging row itself.
     */
    private static List<Id> routedTargets(Inbound_Email_Staging__c row) {
        List<Id> targets = new List<Id>();
        Set<Id> seen = new Set<Id>();

        if (String.isNotBlank(row.Routed_Record_Ids__c)) {
            for (String line : row.Routed_Record_Ids__c.split('\n')) {
                List<String> columns = line.split('\\|');
                if (columns.size() < 3) {
                    continue;
                }
                addTarget(columns[columns.size() - 1].trim(), targets, seen);
            }
        }
        if (targets.isEmpty() && String.isNotBlank(row.Result_Record_Id__c)) {
            addTarget(row.Result_Record_Id__c.trim(), targets, seen);
        }
        return targets;
    }

    /**
     * Add a parsed audit-line value as an Id, ignoring anything that is not one.
     *
     * The audit lines are free text assembled for humans, so a malformed or blank record column
     * is expected rather than exceptional — a gated property writes one. Failing the whole sweep
     * over it would be absurd.
     *
     * @param raw     The parsed column value.
     * @param targets The accumulating ordered target list.
     * @param seen    Ids already added, so a record reached by two properties appears once.
     */
    private static void addTarget(String raw, List<Id> targets, Set<Id> seen) {
        if (String.isBlank(raw)) {
            return;
        }
        try {
            Id recordId = Id.valueOf(raw);
            if (!seen.contains(recordId)) {
                seen.add(recordId);
                targets.add(recordId);
            }
        } catch (Exception e) {
            // Not an Id (a gate line, or a truncated row). Skip it silently — see the Javadoc.
        }
    }
}
