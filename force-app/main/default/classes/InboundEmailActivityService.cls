/**
 * Broker-Protection inbound-email intake — email-activity (Task) layer (staging model).
 * This is the ONLY place the pipeline inserts a Task, and the only place it asks whether
 * a message has already been logged.
 *
 * WHY A TASK AND NOT AN EmailMessage. Enhanced Email / Email-to-Case objects
 * (EmailMessage, EmailMessageRelation) require Enhanced Activities licensing, which this
 * org does NOT have. A completed Task with TaskSubtype 'Email' renders in the standard
 * Activity timeline on Lead, Contact and Opportunity with no licensing dependency, so it
 * is the durable, visible record of "this broker email arrived and here is what it said".
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
 * contains none. Single-record-shaped DML (one inbound email == one Task), never in a
 * loop. Plain `insert` (system mode) matches the module pattern — the inbound-email
 * handler runs in an automated context, and the Task is owned by the Email Service's
 * context user by design (no OwnerId override: the forwarding user is recorded on the
 * Lead's Forwarded_By_Email__c, not by re-owning the activity).
 *
 * @see TaskSelector.cls (the two threading queries)
 * @see PropertyMatchingService.computeThreadKey / findRecordByReplyHeaders
 * @see ExtractAddressQueueable.cls (the only caller)
 */
public with sharing class InboundEmailActivityService {

    /** Task.Status — the inbound email already happened, so its activity is closed. */
    private static final String STATUS_COMPLETED = 'Completed';

    /** Task.TaskSubtype / Task.Type — renders with the email icon in the timeline. */
    private static final String SUBTYPE_EMAIL = 'Email';
    private static final String TYPE_EMAIL = 'Email';

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
     * both threading keys.
     *
     * ATTACHMENT RULE — Task.WhoId accepts only Lead and Contact; Task.WhatId accepts
     * everything else (Opportunity, custom objects) and REJECTS a Lead. The target field is
     * therefore chosen from the Id's own SObjectType, not assumed by the caller. A null
     * `recordId` still inserts the Task, unattached: the Message-ID must be recorded either
     * way or the idempotency check would let the same email be reprocessed forever.
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
        Task activity = new Task(
            Subject = String.isBlank(subject)
                ? SUBJECT_FALLBACK
                : InboundEmailFieldUtil.clip(subject, LEN_SUBJECT),
            Description = InboundEmailFieldUtil.clip(body, LEN_DESCRIPTION),
            ActivityDate = Date.today(),
            Status = STATUS_COMPLETED,
            TaskSubtype = SUBTYPE_EMAIL,
            Type = TYPE_EMAIL,
            Inbound_Message_Id__c = InboundEmailFieldUtil.clip(messageId, LEN_KEY),
            Thread_Key__c = InboundEmailFieldUtil.clip(
                PropertyMatchingService.computeThreadKey(messageId, inReplyTo, references), LEN_KEY)
        );
        attachTo(activity, recordId);
        insert activity;
        return activity.Id;
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
