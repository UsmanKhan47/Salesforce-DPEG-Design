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
 * ⚠ ONE EXCEPTION, ADDED 2026-08-06: `queryCarrierSweep()` is `WITH SYSTEM_MODE`, justified at
 * its own declaration. It backs a SCHEDULED batch — an automation path in the ARCHITECTURE.md §2
 * sense — where a USER_MODE throw would silently disable every retry in the file pipeline. The
 * two record reads are UNCHANGED.
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
     * ── MODE — `WITH SYSTEM_MODE`, and it is the only method in this class that uses it ──
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
}
