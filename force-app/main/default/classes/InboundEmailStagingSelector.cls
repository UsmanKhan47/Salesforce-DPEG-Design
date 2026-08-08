/**
 * Selector for Inbound_Email_Staging__c. Encapsulates ALL SOQL against
 * Inbound_Email_Staging__c per ARCHITECTURE.md §2 and
 * .claude/rules/apex-layering-rule.md ("All SOQL must live in Selector classes.
 * Nothing else queries that object.").
 *
 * Broker Protection module — staging model. Inbound_Email_Staging__c is the DURABLE
 * landing record for every inbound broker email: EmailToLeadHandler writes it
 * synchronously (so the email content and its RFC headers survive even if every later
 * step fails), and ExtractAddressQueueable reads it back asynchronously to run the
 * routing tree. It is the pipeline's audit trail and its restart point.
 *
 * MODE — `WITH USER_MODE` for the two record reads (API 67), matching every other
 * Broker-Protection selector (PropertyRegistrySelector, PropertyClaimLockSelector,
 * CompetingBrokerSubmissionSelector). The Email Service runs Apex as its configured context
 * user, which must hold the Broker_Protection_Access permission set; that permission set needs
 * Inbound_Email_Staging__c object + field permissions added for these reads to succeed (see the
 * deploy note in the feature docs).
 *
 * ⚠ THIS CLASS DELIBERATELY MIXES MODES — READ THE METHOD, NOT THE CLASS. Three methods are
 * `WITH SYSTEM_MODE`, each justified at its own declaration, and all three back AUTOMATION paths
 * in the ARCHITECTURE.md §2 sense (a scheduled batch, or a Finalizer reporting a death nobody
 * asked about) where a `USER_MODE` throw would silently disable a whole retry engine:
 *
 *   queryCarrierSweep()        added 2026-08-06 — the FILE pipeline's work queue
 *   selectRoutingStateById()   added 2026-08-08 — the ROUTING retry's counter read
 *   queryRoutingRetrySweep()   added 2026-08-08 — the ROUTING pipeline's work queue
 *
 * The two record reads that back a human's own inbound email — `selectById` and
 * `selectDroppedNotesById` — are `WITH USER_MODE` and are UNCHANGED.
 *
 * FIELD SET — deliberately WIDE: the queueable consumes almost the whole record
 * (body, subject, envelope addresses, all three RFC threading headers, the resolved
 * monitored inbox). Narrowing it would raise System.SObjectException on the first
 * unselected field read, so add to this list rather than trimming it.
 *
 * NOT-FOUND CONTRACT — returns null, not an exception. A staging record can legitimately
 * be missing by the time the async job runs (hard-deleted during an admin cleanup), and
 * the queueable handles that by logging and returning rather than crashing the job.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see InboundEmailStagingService.cls (the write side)
 */
public with sharing class InboundEmailStagingSelector {

    /**
     * The single staging record for one inbound email, with every field the routing tree
     * reads. Backs ExtractAddressQueueable's first step (load the payload it was enqueued
     * for) via InboundEmailStagingService.getStaging.
     *
     * @param stagingId Inbound_Email_Staging__c Id to load; null returns null.
     * @return The staging record, or null when `stagingId` is null or no row matches.
     * @example
     * Inbound_Email_Staging__c staging = InboundEmailStagingSelector.selectById(stagingId);
     */
    public static Inbound_Email_Staging__c selectById(Id stagingId) {
        if (stagingId == null) {
            return null;
        }
        List<Inbound_Email_Staging__c> rows = [
            SELECT Id, Name, Raw_Body__c, Raw_Headers__c, Subject__c,
                   From_Address__c, From_Name__c, Forwarded_By__c,
                   Message_Id__c, In_Reply_To__c, References__c,
                   Has_Image__c, Image_Mime_Type__c, Attachment_Status__c,
                   Status__c, Outcome__c, Result_Record_Id__c, Processed_DateTime__c, Error__c
            FROM Inbound_Email_Staging__c
            WHERE Id = :stagingId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * The daily carrier-sweep work queue: every staging row whose file pipeline has not reached
     * a terminal state. Backs `AttachmentCarrierSweepBatch.start()`, which is the RETRIED and
     * EXPIRED exits of the carrier's four-exit lifecycle (design §6.4) — without it a carrier
     * that failed conversion would sit on a staging row forever and the whole recoverability
     * story would be theoretical.
     *
     * 🔴 THE THREE STATUSES ARE THE QUEUE, AND THIS IS WHY `Attachment_Status__c` IS A PICKLIST
     * RATHER THAN A NOTE. 'Pending' (the chain never fired), 'Partial' (a heap/budget deferral
     * or a per-file refusal) and 'Failed' (the job died, or the breaker was tripped) all mean
     * "work remains". 'Saved', 'None', 'Not Saved' and 'Expired' are terminal and are excluded
     * BY THE QUERY, which is what makes re-running the sweep free.
     *
     * ⚠ THERE IS DELIBERATELY NO AGE FILTER. The batch must SEE old rows in order to EXPIRE
     * them at `CARRIER_MAX_AGE_DAYS`; filtering them out here would leave exactly the carriers
     * that most need removing invisible to the only thing that removes them.
     *
     * ── MODE — `WITH SYSTEM_MODE` ── ⚠ "the only method in this class that uses it" was true when
     * this was written on 2026-08-06 and was overtaken on 2026-08-08: there are now THREE (see the
     * class header). This one, however, is still the only SYSTEM_MODE method here that runs
     * **with sharing** — the two routing-retry reads had to go further and escape sharing too; see
     * the `RoutingReads` inner class for why, and note that the exposure described there applies to
     * THIS locator as well (recorded in `AttachmentCarrierSweepBatch`'s header, queued as its own
     * change rather than fixed under an unrelated blocker).
     * Deliberate, and NOT a change to the two USER_MODE methods above. This is an automation-path
     * read in the ARCHITECTURE.md §2 sense: a SCHEDULED batch nobody asked for, running as
     * whichever principal happened to schedule it. `WITH USER_MODE` THROWS rather than degrades
     * the instant that principal lacks FLS on one selected field — and Metadata-API-deployed
     * custom fields arrive with NO field permissions for any profile, including System
     * Administrator, so `Attachment_Status__c` would break the sweep for the very administrator
     * who deployed it. A silently disabled retry sweep is the exact class of invisible gap this
     * feature exists to close. SYSTEM_MODE lifts FLS/CRUD only; `with sharing` still governs
     * which records are visible.
     *
     * @return A locator over the non-terminal rows, oldest first so the expiry candidates are
     *         reached before the fresh ones.
     * @example
     * public Database.QueryLocator start(Database.BatchableContext ctx) {
     *     return InboundEmailStagingSelector.queryCarrierSweep();
     * }
     */
    public static Database.QueryLocator queryCarrierSweep() {
        Set<String> workQueue = new Set<String>{
            InboundEmailStagingService.ATTACHMENT_STATUS_PENDING,
            InboundEmailStagingService.ATTACHMENT_STATUS_PARTIAL,
            InboundEmailStagingService.ATTACHMENT_STATUS_FAILED
        };
        return Database.getQueryLocator([
            SELECT Id, CreatedDate, Status__c, Attachment_Status__c,
                   Result_Record_Id__c, Routed_Record_Ids__c
            FROM Inbound_Email_Staging__c
            WHERE Attachment_Status__c IN :workQueue
            WITH SYSTEM_MODE
            ORDER BY CreatedDate ASC
        ]);
    }

    /**
     * The current Dropped_Attachment_Notes__c value, and nothing else. Backs
     * InboundEmailStagingService.appendDroppedNote, which must READ before it APPENDS
     * because the notes accumulate across two transactions: classification drops are
     * written by createStaging at the synchronous boundary, and ContentDocumentLink
     * refusals arrive later from the async router.
     *
     * ⚠ THIS IS DELIBERATELY A SEPARATE, NARROW METHOD RATHER THAN A FIELD ADDED TO
     * selectById. selectById is on the pipeline's CRITICAL PATH — it is the first thing
     * ExtractAddressQueueable does — and it is `WITH USER_MODE`, which THROWS rather than
     * degrades when the running principal lacks FLS on any selected field. Adding a
     * brand-new custom field there would make every inbound email depend on that field's
     * FLS having been granted. Here the same denial costs only the note, because every
     * caller of appendDroppedNote is fail-soft by design.
     *
     * @param stagingId Inbound_Email_Staging__c Id to read; null returns null.
     * @return The row carrying only Id + Dropped_Attachment_Notes__c, or null when
     *         `stagingId` is null or no row matches.
     * @example
     * Inbound_Email_Staging__c row =
     *     InboundEmailStagingSelector.selectDroppedNotesById(stagingId);
     */
    public static Inbound_Email_Staging__c selectDroppedNotesById(Id stagingId) {
        if (stagingId == null) {
            return null;
        }
        List<Inbound_Email_Staging__c> rows = [
            SELECT Id, Dropped_Attachment_Notes__c
            FROM Inbound_Email_Staging__c
            WHERE Id = :stagingId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * The ROUTING retry state of one staging row — its status, its accumulated error text, how
     * many times routing has already died on it, and its Message-ID. Backs
     * `InboundEmailStagingService.markRoutingFailed`, which is called from
     * `RoutingFailureFinalizer` after the routing job has already rolled itself back.
     *
     * ⚠ DELIBERATELY A SEPARATE, NARROW METHOD RATHER THAN FIELDS ADDED TO `selectById` — the
     * SAME reasoning `selectDroppedNotesById` carries, and here it is sharper still.
     * `selectById` is the FIRST thing every inbound email does and it is `WITH USER_MODE`, which
     * THROWS rather than degrades on any FLS gap. Adding the brand-new `Routing_Attempt_Count__c`
     * there would make EVERY inbound broker email depend on that field's FLS having been granted —
     * i.e. the change made to protect the pipeline would become the pipeline's newest single point
     * of failure. Here the same denial costs only the failure record, and this method does not use
     * USER_MODE at all.
     *
     * `Message_Id__c` is selected even though `markRoutingFailed` does not read it: it is the
     * discriminator the design's §3.3 stale-`Pending` queue needs (a blank Message-ID means the
     * redelivery guard cannot protect a replay, so such a row must be left for a human). Selecting
     * it now costs nothing and keeps that decision one method away rather than one query away.
     *
     * ── MODE — `WITH SYSTEM_MODE`, justified here ──
     * An AUTOMATION path in the ARCHITECTURE.md §2 sense: the caller is a Finalizer running after
     * an unhandled failure, under whichever principal the platform happened to execute the job as.
     * `WITH USER_MODE` THROWS rather than degrades the instant that principal lacks FLS on one
     * selected field — and a Metadata-API-deployed custom field arrives with NO field permissions
     * for ANY profile, System Administrator included, so `Routing_Attempt_Count__c` under
     * USER_MODE would break the failure recorder for the very administrator who deployed it. A
     * failure to record a failure must not become a second failure.
     *
     * 🔴 ── AND SHARING, WHICH IS A SEPARATE DECISION — SEE THE `RoutingReads` INNER CLASS ──
     * `SYSTEM_MODE` lifts FLS/CRUD ONLY and does **not** lift record sharing. On this Private-OWD
     * object that would scope the read to rows the running principal owns, so the actual SOQL
     * lives in the `without sharing` inner class `RoutingReads`; this method is the wrapper.
     * A null return here would stop the attempt counter incrementing, which is an infinite
     * hourly re-dispatch loop, not an inert failure. Read that class's header before touching
     * either mode.
     *
     * @param stagingId Inbound_Email_Staging__c Id to read; null returns null.
     * @return The row carrying only the routing-state fields, or null when `stagingId` is null
     *         or no row matches (the row was hard-deleted between the failure and this read).
     * @example
     * Inbound_Email_Staging__c row =
     *     InboundEmailStagingSelector.selectRoutingStateById(stagingId);
     */
    public static Inbound_Email_Staging__c selectRoutingStateById(Id stagingId) {
        if (stagingId == null) {
            return null;
        }
        return new RoutingReads().routingStateById(stagingId);
    }

    /**
     * The routing retry work queue: every staging row whose routing transaction DIED with an
     * unhandled exception. Backs `RoutingRetrySweepBatch.start()`.
     *
     * 🔴 `Status__c = 'Failed'` IS THE WHOLE FILTER, AND THAT IS A SAFETY PROOF RATHER THAN A
     * PREFERENCE. `'Failed'` is written by one thing only — `RoutingFailureFinalizer`, which fires
     * only on `ParentJobResult.UNHANDLED_EXCEPTION`. SP-5 measured that an unhandled exception
     * rolls back the queueable's OWN DML, so a `'Failed'` row provably carries no Lead, no registry
     * claim, no submission, no Task and no stamp from that attempt, and a replay is byte-for-byte
     * a first run. `'Error'` means the opposite — the catch RAN, so work MAY have committed — and
     * replaying one can mint a second Lead or file a winning broker as a competing submission
     * against their own Lead. **`'Error'` and `'Pending'` must never be added to this query.**
     *
     * ⚠ THERE IS DELIBERATELY NO AGE FILTER, for the identical reason `queryCarrierSweep` has
     * none: the batch must SEE old rows in order to ABANDON them at the age cap. Filtering them
     * out here would leave exactly the rows that most need a terminal state invisible to the only
     * thing that can give them one.
     *
     * FIELD SET — everything `RoutingRetrySweepBatch` needs to decide AND to record, so the batch
     * itself holds no SOQL: `Routing_Attempt_Count__c` and `CreatedDate` for the two caps, and
     * `Error__c` so an abandon can APPEND rather than overwrite without re-reading the row inside
     * the sweep loop.
     *
     * ── MODE — `WITH SYSTEM_MODE`, justified here ──
     * Same automation-path reasoning as `queryCarrierSweep`: a SCHEDULED batch nobody asked for,
     * running as whichever principal happened to schedule it, over a field
     * (`Routing_Attempt_Count__c`) that a Metadata-API deploy grants to no profile at all. A
     * `USER_MODE` throw would not degrade the sweep — it would silently disable every routing
     * retry in the design, which is the exact class of invisible gap the feature exists to close.
     *
     * 🔴 ── AND SHARING, SEPARATELY — SEE THE `RoutingReads` INNER CLASS ── `SYSTEM_MODE` does not
     * lift sharing, and under `with sharing` this locator would return only the rows the
     * SCHEDULING user owns: the sweep would report `dispatched=0` and look perfectly healthy. The
     * SOQL therefore lives in the `without sharing` inner class; this method is the wrapper.
     *
     * @return A locator over the failed rows, oldest first so the abandon candidates are reached
     *         before the fresh ones.
     * @example
     * public Database.QueryLocator start(Database.BatchableContext ctx) {
     *     return InboundEmailStagingSelector.queryRoutingRetrySweep();
     * }
     */
    public static Database.QueryLocator queryRoutingRetrySweep() {
        return new RoutingReads().retrySweepLocator();
    }

    /**
     * 🔴 THE ROUTING RETRY ENGINE'S READS, WHICH MUST RUN **WITHOUT SHARING**.
     *
     * ═══ WHY — `WITH SYSTEM_MODE` IS NOT ENOUGH, AND THIS CLASS'S OWN JAVADOC SAYS SO ═══
     * `SYSTEM_MODE` lifts FLS and CRUD **only**; it does NOT lift record sharing. And
     * `Inbound_Email_Staging__c` is `sharingModel = Private` with **no** sharing rules, while
     * `Broker_Protection_Access` sets `viewAllRecords = false`. Staging rows are owned by whoever
     * inserted them — the Email Service context user, since `createStaging` sets no `OwnerId`.
     *
     * So with `with sharing` these two reads return **only the rows the SCHEDULING user happens to
     * own**. The retry sweep would then dispatch nothing and `finish()` would log
     * `dispatched=0 abandoned=0 skipped=0 failed=0` — **byte-identical to a healthy pipeline with
     * nothing to retry.** That is the R1-shaped silent failure this entire feature exists to
     * eliminate, reproduced inside the fix: it would work on day one because an administrator
     * schedules it, and would die invisibly the day that administrator is deactivated.
     *
     * The counter read is the sharper of the two, because its failure is not merely inert — it is
     * a LOOP. `markRoutingFailed` returning null means the attempt counter never increments, so the
     * row never reaches the cap, so the sweep re-dispatches it every hour forever, silently.
     *
     * ═══ PRECEDENT ═══
     * Identical in shape and in argument to `LeadSelector.GuestReads` / `ContactSelector.GuestReads`,
     * and to `EmailThreadGuardService`, which is `without sharing` because it must clean EVERY Lead
     * the capture landed on rather than the subset the automated principal can see. An automation
     * that must act on ALL matching rows cannot be scoped by an incidental principal's sharing.
     *
     * ═══ SCOPE — DELIBERATELY AS NARROW AS APEX ALLOWS ═══
     * Inner classes do NOT inherit the outer class's sharing, so this is declared explicitly and
     * the outer `InboundEmailStagingSelector` **stays `with sharing`**. It is `private`, so the
     * only way in is through the two public static wrappers above — nothing outside this file can
     * borrow an unshared read of this object. `selectById` and `selectDroppedNotesById` are
     * untouched and remain `with sharing` + `WITH USER_MODE`.
     *
     * ⚠ Apex forbids static methods on inner classes, hence the instance methods and the
     * `new RoutingReads()` at each call site.
     *
     * 🔴 RESIDUAL THIS DOES **NOT** CLOSE — see `RoutingRetrySweepSchedule`'s header. Fixing the
     * engine's own reads does not fix the job it DISPATCHES: the retried `ExtractAddressQueueable`
     * loads the row through `selectById`, which is `with sharing` and is deliberately out of scope
     * for this change. That leg is closed operationally, by requiring the schedule to be owned by a
     * principal with View All on this object.
     */
    private without sharing class RoutingReads {

        /**
         * The routing state of one row, read without sharing. See `selectRoutingStateById` for the
         * field set and the `SYSTEM_MODE` justification, and the enclosing class for the sharing
         * one.
         *
         * @param stagingId The row to read; never null (the wrapper guards it).
         * @return The row, or null when no row matches.
         */
        private Inbound_Email_Staging__c routingStateById(Id stagingId) {
            List<Inbound_Email_Staging__c> rows = [
                SELECT Id, Status__c, Error__c, Routing_Attempt_Count__c, Message_Id__c
                FROM Inbound_Email_Staging__c
                WHERE Id = :stagingId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            return rows.isEmpty() ? null : rows[0];
        }

        /**
         * The retry work queue, read without sharing. See `queryRoutingRetrySweep` for the
         * `Failed`-only safety proof and the absence of an age filter.
         *
         * @return A locator over every failed row in the org, oldest first.
         */
        private Database.QueryLocator retrySweepLocator() {
            String failed = InboundEmailStagingService.STATUS_FAILED;
            return Database.getQueryLocator([
                SELECT Id, CreatedDate, Status__c, Error__c, Routing_Attempt_Count__c
                FROM Inbound_Email_Staging__c
                WHERE Status__c = :failed
                WITH SYSTEM_MODE
                ORDER BY CreatedDate ASC
            ]);
        }
    }
}
