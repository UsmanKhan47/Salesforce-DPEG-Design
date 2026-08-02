/**
 * Broker-Protection inbound-email intake — email-activity (Task) layer (staging model).
 * This is the ONLY place the pipeline inserts a Task, and the only place it asks whether
 * a message has already been logged.
 *
 * ═══ WHY THIS TASK SETS TaskSubtype AND NEVER Type — the 2026-07-31 outage ═══
 *
 * ⚠ RETRACTION. An earlier version of this header blamed Enhanced Email for "reserving"
 * TaskSubtype 'Email' for EmailMessage-born tasks. THAT WAS WRONG and is retracted. An
 * in-org field-by-field bisect falsified it: with Enhanced Email ON in `usman-dpeg`, a Task
 * carrying TaskSubtype = 'Email' plus WhoId and both custom threading keys was created and
 * deleted successfully. TaskSubtype is fine. The culprit was the OTHER field on the same line.
 *
 * THE REAL CAUSE — `Task.Type` DOES NOT EXIST IN THIS ORG. It is absent from FieldDefinition
 * entirely. This is an ORG-TEMPLATE difference, not a licensing or feature toggle:
 * Enhanced-Email-era org templates retired the classic activity `Type` picklist in favour of
 * `TaskSubtype`. Setting it fails every time:
 *   • via REST  — INVALID_FIELD, "No such column 'Type' on sobject of type Task"
 *   • via Apex  — COMPILES (the Apex compiler resolves Task.Type against the standard object
 *                 schema, not this org's field set) and then throws at runtime:
 *                 "Operation failed due to fields being inaccessible on Sobject Task"
 * The compile-time silence is why this survived every review and every deploy.
 *
 * WHY IT SURFACED ONLY NOW — it was LATENT FROM THE MODULE'S FIRST DEPLOY to this org, not
 * introduced by any recent change. The builder orgs (SDO-1Year, scratch orgs) still carry
 * classic `Type`, so everything was green there. The two inbound broker emails on 2026-07-31
 * were simply THE FIRST REAL EXECUTIONS of this code path in `usman-dpeg`; both died here and
 * were left on their staging rows as Status 'Error'. Enabling Enhanced Email for Einstein
 * Activity Capture was coincident, not causal.
 *
 * ⚠ PORTABILITY RULE — DO NOT "RESTORE" Task.Type. An org still on a classic template WILL
 * accept it, so a green run elsewhere proves nothing. The field must never be set by this
 * module: it is unavailable in Enhanced-Email-era orgs and hard-fails there, while
 * TaskSubtype is available in both. TaskSubtype alone is the portable choice, and it is what
 * renders the email icon on the Activity timeline.
 *
 * NOTE — the repo still contains objects/Task/fields/Type.field-meta.xml, a snapshot
 * retrieved from a classic-template org. It is inert here but is NOT evidence that the field
 * exists in this org; trust FieldDefinition, not the repo.
 *
 * WHY A TASK AND NOT AN EmailMessage. Enhanced Email IS now enabled in this org (via EAC
 * setup), so EmailMessage-based logging has become technically possible — but the Task model
 * is retained deliberately. The THREAD-ANCHOR CONTRACT is what matters and is unchanged:
 * Inbound_Message_Id__c (idempotency) and Thread_Key__c (conversation root) are stamped here
 * and read by TaskSelector. The EAC Thread Guard (Change 2) decides what to delete purely by
 * matching those anchors, so relocating them would silently disarm it. Migrating to
 * EmailMessage is a separate, deliberate change — not an outage fix.
 *
 * NO SUBTYPE-ERA SPLIT EXISTS. A concern was raised about heterogeneous TaskSubtype values
 * across pipeline Tasks. It is moot: ZERO pipeline Tasks have ever been successfully inserted
 * in this org (every attempt died on Type), so there is no historical population to be
 * inconsistent with.
 *
 * TWO THREADING KEYS, TWO JOBS — both are External Id text fields on Task:
 *   • Inbound_Message_Id__c — THIS message's RFC Message-ID. Unique per email, so it is
 *     the IDEMPOTENCY key: if a Task already carries it, the platform is redelivering a
 *     message that was already processed and the whole routing tree must be skipped.
 *   • Thread_Key__c — the CONVERSATION ROOT Message-ID (see
 *     PropertyMatchingService.computeThreadKey). Shared by every message in a thread and
 *     preserved across forwards, so a later reply can be matched back to the record the
 *     original email was routed to.
 *
 * LAYER — Service (Task write side). All SOQL delegates to TaskSelector; this class
 * contains none. Plain `insert` (system mode) matches the module pattern — the inbound-email
 * handler runs in an automated context, and the Task is owned by the Email Service's
 * context user by design (no OwnerId override: the forwarding user is recorded on the
 * Lead's Forwarded_By_Email__c, not by re-owning the activity).
 *
 * ⚠ DML SHAPE CHANGED 2026-07-31 (D1 multi-property). This class used to be
 * single-record-shaped on the invariant "one inbound email == one Task". That is no longer
 * true: one email can route to SEVERAL records, so the primary method now takes a
 * List&lt;Id&gt; and does ONE bulk insert of N Tasks. The single-Id method survives as a
 * one-element wrapper. The bulk method's Javadoc carries the full reasoning — including
 * why N rows sharing one Message-ID is safe and why their INSERT ORDER is load-bearing for
 * reply threading.
 *
 * @see TaskSelector.cls (the two threading queries)
 * @see PropertyMatchingService.computeThreadKey / findRecordByReplyHeaders
 * @see ExtractAddressQueueable.cls (the only caller)
 */
public with sharing class InboundEmailActivityService {

    /** Task.Status — the inbound email already happened, so its activity is closed. */
    private static final String STATUS_COMPLETED = 'Completed';

    /** Task.TaskSubtype — renders the email icon in the Activity timeline. There is
     *  deliberately NO Task.Type counterpart: that field does not exist in Enhanced-Email-era
     *  orgs (including this one), compiles anyway, and throws at runtime. See the class
     *  header. TaskSubtype is available in both org templates and is the portable choice. */
    private static final String SUBTYPE_EMAIL = 'Email';

    /** Subject fallback: Task.Subject is what the timeline shows, so it is never left blank. */
    private static final String SUBJECT_FALLBACK = '(no subject)';

    /** Destination field lengths. */
    private static final Integer LEN_SUBJECT = 255;
    private static final Integer LEN_DESCRIPTION = 32000;
    private static final Integer LEN_KEY = 255;

    /**
     * True when this exact RFC Message-ID has already been logged as a Task — i.e. the
     * platform is redelivering a message the pipeline has already routed.
     *
     * A BLANK message id returns false (not "already logged"). Some forwarding paths strip
     * Message-ID, and refusing to process those emails would be worse than processing a
     * rare duplicate: the idempotency guarantee is best-effort and degrades gracefully.
     *
     * @param messageId The inbound RFC Message-ID; blank returns false.
     * @return true when a Task already carries this Message-ID.
     * @example
     * if (InboundEmailActivityService.isAlreadyLogged(messageId)) { ...skip... }
     */
    public static Boolean isAlreadyLogged(String messageId) {
        if (String.isBlank(messageId)) {
            return false;
        }
        return !TaskSelector.selectByInboundMessageId(messageId).isEmpty();
    }

    /**
     * Log one inbound broker email as a completed Task attached to `recordId`, carrying
     * both threading keys. A one-element convenience wrapper over the bulk method below —
     * kept so single-target callers (and their tests) read as one line.
     *
     * @param recordId   The record the routing tree resolved (Lead / Contact / Opportunity
     *                   / other); may be null.
     * @param subject    The inbound email subject, used verbatim as the Task Subject.
     * @param body       The raw email body → Task.Description.
     * @param messageId  RFC Message-ID of this email → Inbound_Message_Id__c.
     * @param inReplyTo  RFC In-Reply-To header (used only to derive the thread key).
     * @param references RFC References header (used only to derive the thread key).
     * @return The Id of the inserted Task.
     * @throws DmlException when the Task insert fails; the caller records it on the
     *         staging row's Error__c alongside the outcome it had already reached.
     * @example
     * InboundEmailActivityService.logInboundEmail(
     *     leadId, staging.Subject__c, staging.Raw_Body__c,
     *     staging.Message_Id__c, staging.In_Reply_To__c, staging.References__c);
     */
    public static Id logInboundEmail(Id recordId, String subject, String body,
                                     String messageId, String inReplyTo, String references) {
        List<Task> logged = logInboundEmail(
            new List<Id>{ recordId }, subject, body, messageId, inReplyTo, references);
        return logged[0].Id;
    }

    /**
     * Log ONE inbound broker email onto SEVERAL records — one Task per record, all inserted
     * in a single DML, all carrying the SAME Message-ID and the SAME Thread-Key.
     *
     * ═══ WHY ONE TASK PER ROUTED RECORD, AND NOT ONE PER EMAIL (C-2) ═══
     * A multi-property email can route to several records at once: a new Lead for the
     * property this broker won, plus a DIFFERENT broker's winning Lead for a property they
     * lost, plus the record an earlier submission already produced. Logging a single Task
     * would leave a competing submission with NO EMAIL BEHIND IT on the winner's record —
     * a claim nobody can audit, in a module whose whole premise is that the property's
     * entire story lives in one place. Logging one Task per PROPERTY instead would
     * double-log the same email whenever two properties resolve to the same record, which
     * is why the caller de-duplicates the target list by record Id first.
     *
     * ═══ WHY N TASKS SHARING ONE MESSAGE-ID IS SAFE (verified, not assumed) ═══
     *   • Inbound_Message_Id__c is `externalId` with NO `unique` element, so N rows carrying
     *     one Message-ID insert cleanly. It is a non-unique External Id by design.
     *   • isAlreadyLogged reads through TaskSelector.selectByInboundMessageId, which is
     *     LIMIT 1 and tests only `.isEmpty()` — so idempotency is completely unaffected by
     *     there being several rows.
     *   • Thread_Key__c is the CONVERSATION ROOT and is shared by every message in a thread
     *     by design; identical values across the N rows is correct, not a collision.
     *
     * ⚠ ORDER IS LOAD-BEARING (C-3). The caller passes `recordIds` in ASCENDING PRIORITY
     * (no-property &lt; repeat &lt; competing &lt; winner) because a later reply into this thread is
     * resolved by TaskSelector.selectLatestByThreadOrMessageIds, which orders
     * `CreatedDate DESC, Id DESC`. N rows inserted in ONE DML share a CreatedDate to the
     * millisecond, so the Id tie-break decides — and inserting the highest-priority record
     * LAST gives it the highest Id, which lands the reply on the deal DPEG actually owns
     * instead of on an arbitrary row.
     *
     * A NULL element, or an empty/null list, still inserts a Task — unattached. That is
     * deliberate: the Message-ID must be recorded even when routing produced no record at
     * all (a gated or pre-filtered email), or the idempotency check would let the platform
     * reprocess the same message forever.
     *
     * @param recordIds  Distinct routed records in ascending priority; null/empty logs one
     *                   unattached Task.
     * @param subject    The inbound email subject, used verbatim as the Task Subject.
     * @param body       The raw email body → Task.Description.
     * @param messageId  RFC Message-ID of this email → Inbound_Message_Id__c.
     * @param inReplyTo  RFC In-Reply-To header (used only to derive the thread key).
     * @param references RFC References header (used only to derive the thread key).
     * @return The inserted Tasks, in the same order as `recordIds`.
     * @throws DmlException when the Task insert fails; the caller records it on the
     *         staging row's Error__c alongside the outcome it had already reached.
     * @example
     * InboundEmailActivityService.logInboundEmail(
     *     orderedTargets, staging.Subject__c, staging.Raw_Body__c,
     *     staging.Message_Id__c, staging.In_Reply_To__c, staging.References__c);
     */
    public static List<Task> logInboundEmail(List<Id> recordIds, String subject, String body,
                                             String messageId, String inReplyTo, String references) {
        // Both threading keys are identical on every row, so they are computed ONCE rather
        // than per Task — computeThreadKey is pure but it is not free.
        String clippedSubject = String.isBlank(subject)
            ? SUBJECT_FALLBACK
            : InboundEmailFieldUtil.clip(subject, LEN_SUBJECT);
        String clippedBody = InboundEmailFieldUtil.clip(body, LEN_DESCRIPTION);
        String clippedMessageId = InboundEmailFieldUtil.clip(messageId, LEN_KEY);
        String threadKey = InboundEmailFieldUtil.clip(
            PropertyMatchingService.computeThreadKey(messageId, inReplyTo, references), LEN_KEY);

        List<Id> targets = (recordIds == null || recordIds.isEmpty())
            ? new List<Id>{ null }
            : recordIds;

        List<Task> activities = new List<Task>();
        for (Id recordId : targets) {
            Task activity = new Task(
                Subject = clippedSubject,
                Description = clippedBody,
                ActivityDate = Date.today(),
                Status = STATUS_COMPLETED,
                // TaskSubtype only. Never add Task.Type here — it does not exist in this
                // org, compiles regardless, and throws at runtime. See the class header.
                TaskSubtype = SUBTYPE_EMAIL,
                Inbound_Message_Id__c = clippedMessageId,
                Thread_Key__c = threadKey
            );
            attachTo(activity, recordId);
            activities.add(activity);
        }
        insert activities;
        return activities;
    }

    /**
     * Point the Task at `recordId` using the field that record type actually accepts:
     * WhoId for Lead / Contact, WhatId for anything else. A null Id leaves both unset.
     *
     * @param activity The unsaved Task to stamp.
     * @param recordId The routed record; null leaves the Task unattached.
     */
    private static void attachTo(Task activity, Id recordId) {
        if (recordId == null) {
            return;
        }
        Schema.SObjectType targetType = recordId.getSObjectType();
        if (targetType == Lead.SObjectType || targetType == Contact.SObjectType) {
            activity.WhoId = recordId;
        } else {
            activity.WhatId = recordId;
        }
    }
}
