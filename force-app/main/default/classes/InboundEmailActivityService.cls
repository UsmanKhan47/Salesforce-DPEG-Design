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
 * ═══ THE TASK NOW RECORDS WHO SENT THE EMAIL (2026-08-04) ═══
 * Until this change the Task carried the subject and the body and NOTHING about the sender —
 * not a name, not an address, not a direction. On a Lead's Activity timeline that produced the
 * reported defect: an inbound broker email rendered as "You sent an email" with no indication
 * anywhere of who it had actually come from.
 *
 * WHY THE SENDER GOES ON `Subject` AND NOT ONLY INTO `Description`. The COLLAPSED timeline row
 * renders `Subject` ONLY. A sender recorded anywhere else is invisible until the row is
 * expanded — which is precisely the moment the reader has already been misled. So `Subject`
 * carries a `From &lt;sender&gt;: ` prefix (buildSubject) and `Description` gains a header block
 * with the address and the UNTRUNCATED original subject (buildDescription). The two are
 * complementary, not redundant: the prefix shares the 255-character Subject budget, so the
 * Description's `Subject:` line is the guarantee that the full subject survives somewhere.
 *
 * ⚠ THIS DOES NOT FIX THE "You sent an email" CHROME, AND NOTHING ON A TASK CAN. Direction is
 * not a Task attribute — the Lightning timeline derives that line from `EmailMessage.Incoming`,
 * and a standalone Task has no counterpart field to set. The prefix is a MITIGATION (the
 * broker's name now sits immediately beneath the wrong line), not a cure. Removing the line
 * requires migrating this module to EmailMessage, which was assessed and RECOMMENDED AGAINST on
 * two independent grounds: it would relocate the thread anchors onto a PLATFORM-OWNED companion
 * Task — destroying the EAC Thread Guard's structural-unreachability guarantee, and losing
 * Inbound_Message_Id__c silently breaks idempotency — and an EmailMessage cannot reliably reach
 * a LEAD at all, because a sender address that already belongs to a Contact makes every
 * EmailMessageRelation fail with "An email can't have more than 1 sender" (measured in
 * `usman-dpeg`, 2026-08-02), which is the shape of every repeat broker this module exists for.
 * Do not re-litigate it without reading `agent-output/design-requirements.md` §4.
 *
 * ⚠ CONTRACT NOTE — `Task.Subject` IS NOT A MATCHING KEY, AND MUST STAY THAT WAY. Nothing in
 * this repo queries pipeline Tasks by Subject (the two subject-matching TaskSelector methods
 * belong to the Disposition closing checklist and the broker check-in reminder; both match
 * literal internal subjects scoped by WhatId and cannot collide with a `From `-prefixed email
 * subject). Idempotency and reply threading match on Inbound_Message_Id__c / Thread_Key__c
 * ONLY, and neither of those changed. A future Subject-based probe would now have to account
 * for the prefix — prefer a field over re-deriving meaning from this string.
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
     * Sender-prefix vocabulary for Task.Subject.
     *
     * ⚠ SUBJECT_SENDER_PREFIX is `'From '` with NO colon. The colon lives in
     * SUBJECT_SENDER_SEPARATOR, AFTER the sender, so the composed line reads
     * `From Jane Broker: 1400 Royal Ln`. The Description header block uses a DIFFERENT,
     * RFC-shaped label (`'From: '`, colon immediately after the word). The two are similar
     * enough to swap by accident and are not interchangeable.
     */
    private static final String SUBJECT_SENDER_PREFIX = 'From ';
    private static final String SUBJECT_SENDER_SEPARATOR = ': ';

    /**
     * The sender label's own budget INSIDE the 255-character Subject. It exists so a
     * pathological display name cannot eat the subject: the sender is clipped to 60 BEFORE the
     * composed string is clipped to 255, so the prefix costs at most 5 + 60 + 2 = 67 characters
     * and AT LEAST 188 characters of the original subject always survive. See buildSubject.
     */
    private static final Integer LEN_SUBJECT_SENDER = 60;

    /**
     * Budget for the address shown on the Description's `From:` line — Salesforce's standard
     * Email-field length. It is a DISPLAY bound only: Description is a text field, so nothing
     * here can throw INVALID_EMAIL_ADDRESS, and the value is deliberately NOT run through
     * InboundEmailFieldUtil.sanitizeEmail (which returns null for anything malformed and would
     * therefore HIDE information — see buildDescription).
     */
    private static final Integer LEN_SENDER_EMAIL = 80;

    /**
     * Shown on the Description's `From:` line when neither a name nor an address is known. That
     * line is ALWAYS emitted — "the pipeline could not identify a sender" is itself information
     * the reader needs, and its absence would read as an oversight rather than a fact.
     */
    private static final String SENDER_UNKNOWN = '(sender not identified)';

    /**
     * Plain 60-hyphen rule closing the Description header block. ASCII on purpose: this text
     * lands in a 32,000-character field that is also read by scripts and exports, so no
     * box-drawing characters and nothing outside ASCII.
     */
    private static final String HEADER_RULE =
        '------------------------------------------------------------';

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
     * Log one inbound broker email as a completed Task attached to `recordId`, carrying both
     * threading keys AND the sender's identity. A one-element convenience wrapper over the bulk
     * method below — kept so single-target callers (and their tests) read as one line.
     *
     * ⚠ THERE IS DELIBERATELY NO SENDER-LESS OVERLOAD of either method. The 6-argument forms
     * were REMOVED rather than retained on 2026-08-04: keeping them would let a future caller
     * silently log a Task with no sender on it, reintroducing the exact defect this change
     * fixes. Pass blanks explicitly if the sender is genuinely unknown — buildSubject then
     * degrades to the pre-change Subject, byte for byte.
     *
     * @param recordId    The record the routing tree resolved (Lead / Contact / Opportunity
     *                    / other); may be null.
     * @param subject     The inbound email subject; composed into the Task Subject.
     * @param body        The raw email body → Task.Description, beneath the sender header.
     * @param messageId   RFC Message-ID of this email → Inbound_Message_Id__c.
     * @param inReplyTo   RFC In-Reply-To header (used only to derive the thread key).
     * @param references  RFC References header (used only to derive the thread key).
     * @param senderName  Display name of the broker who sent the email; blank falls back to
     *                    `senderEmail`, and blank BOTH suppresses the Subject prefix entirely.
     * @param senderEmail The broker's address; display only, never an arbitration key.
     * @return The Id of the inserted Task.
     * @throws DmlException when the Task insert fails; the caller records it on the
     *         staging row's Error__c alongside the outcome it had already reached.
     * @example
     * InboundEmailActivityService.logInboundEmail(
     *     leadId, staging.Subject__c, staging.Raw_Body__c,
     *     staging.Message_Id__c, staging.In_Reply_To__c, staging.References__c,
     *     senderName, senderEmail);
     */
    public static Id logInboundEmail(Id recordId, String subject, String body,
                                     String messageId, String inReplyTo, String references,
                                     String senderName, String senderEmail) {
        List<Task> logged = logInboundEmail(
            new List<Id>{ recordId }, subject, body, messageId, inReplyTo, references,
            senderName, senderEmail);
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
     * @param recordIds   Distinct routed records in ascending priority; null/empty logs one
     *                    unattached Task.
     * @param subject     The inbound email subject; composed into the Task Subject.
     * @param body        The raw email body → Task.Description, beneath the sender header.
     * @param messageId   RFC Message-ID of this email → Inbound_Message_Id__c.
     * @param inReplyTo   RFC In-Reply-To header (used only to derive the thread key).
     * @param references  RFC References header (used only to derive the thread key).
     * @param senderName  Display name of the broker who sent the email; blank falls back to
     *                    `senderEmail`, and blank BOTH suppresses the Subject prefix entirely.
     * @param senderEmail The broker's address; display only, never an arbitration key.
     * @return The inserted Tasks, in the same order as `recordIds`.
     * @throws DmlException when the Task insert fails; the caller records it on the
     *         staging row's Error__c alongside the outcome it had already reached.
     * @example
     * InboundEmailActivityService.logInboundEmail(
     *     orderedTargets, staging.Subject__c, staging.Raw_Body__c,
     *     staging.Message_Id__c, staging.In_Reply_To__c, staging.References__c,
     *     senderName, senderEmail);
     */
    public static List<Task> logInboundEmail(List<Id> recordIds, String subject, String body,
                                             String messageId, String inReplyTo, String references,
                                             String senderName, String senderEmail) {
        // Every row of this batch is the SAME email, so both threading keys and both composed
        // display strings are identical across the N Tasks and are built ONCE rather than per
        // Task — computeThreadKey and the composers are pure, but they are not free.
        String composedSubject = buildSubject(senderName, senderEmail, subject);
        String composedDescription = buildDescription(senderName, senderEmail, subject, body);
        String clippedMessageId = InboundEmailFieldUtil.clip(messageId, LEN_KEY);
        String threadKey = InboundEmailFieldUtil.clip(
            PropertyMatchingService.computeThreadKey(messageId, inReplyTo, references), LEN_KEY);

        List<Id> targets = (recordIds == null || recordIds.isEmpty())
            ? new List<Id>{ null }
            : recordIds;

        List<Task> activities = new List<Task>();
        for (Id recordId : targets) {
            Task activity = new Task(
                Subject = composedSubject,
                Description = composedDescription,
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
     * Compose Task.Subject: `From &lt;sender&gt;: &lt;original subject&gt;`.
     *
     * ═══ WHY THE SENDER GOES FIRST — THE TRUNCATION CONTRACT ═══
     * InboundEmailFieldUtil.clip is HEAD-PRESERVING (`substring(0, max)`), so whatever sits at
     * the front of the composed string survives and the TAIL is what a 255-character field
     * discards. Putting the sender first is therefore not a cosmetic choice — it is what makes
     * "the sender can never be truncated away" true by construction:
     *
     *   • the sender is clipped to LEN_SUBJECT_SENDER (60) FIRST, so a pathological 300-character
     *     display name cannot eat the subject;
     *   • the prefix therefore costs at most 5 (`'From '`) + 60 + 2 (`': '`) = 67 characters, so
     *     AT LEAST 188 characters of the original subject always remain in Subject;
     *   • what is lost above 255 is the ORIGINAL SUBJECT'S TAIL. That is the correct trade: the
     *     sender is the information the reader is missing, and the FULL subject is preserved
     *     unabridged on the Description's `Subject:` line (see buildDescription) and verbatim on
     *     `Inbound_Email_Staging__c.Subject__c`.
     *
     * Typical broker subjects run 40–90 characters, so in practice nothing is lost at all.
     *
     * ═══ THE THREE FALLBACKS ═══
     *   1. NAME BLANK, ADDRESS KNOWN  → the ADDRESS becomes the sender label.
     *   2. BOTH BLANK                 → NO PREFIX AT ALL. The Subject is then byte-identical to
     *      the pre-2026-08-04 behaviour. This keeps the change strictly additive and avoids
     *      emitting a dangling `From : ` or a noisy `From (unknown): `.
     *   3. SUBJECT BLANK              → the existing SUBJECT_FALLBACK is substituted INSIDE the
     *      composition, so the result is `From Jane Broker: (no subject)` and never a trailing
     *      `From Jane Broker: `.
     *
     * @param senderName  The broker's display name; blank falls back to `senderEmail`.
     * @param senderEmail The broker's address; used as the label only when the name is blank.
     * @param subject     The original inbound subject; blank yields SUBJECT_FALLBACK.
     * @return The composed Subject, never longer than LEN_SUBJECT and never blank.
     */
    private static String buildSubject(String senderName, String senderEmail, String subject) {
        String baseSubject = String.isBlank(subject) ? SUBJECT_FALLBACK : subject;

        String senderLabel = String.isNotBlank(senderName)
            ? senderName.trim()
            : (String.isNotBlank(senderEmail) ? senderEmail.trim() : null);

        if (senderLabel == null) {
            // Fallback 2 — no sender was resolved on any path, so emit no prefix.
            return InboundEmailFieldUtil.clip(baseSubject, LEN_SUBJECT);
        }

        return InboundEmailFieldUtil.clip(
            SUBJECT_SENDER_PREFIX
                + InboundEmailFieldUtil.clip(senderLabel, LEN_SUBJECT_SENDER)
                + SUBJECT_SENDER_SEPARATOR
                + baseSubject,
            LEN_SUBJECT);
    }

    /**
     * Compose Task.Description: a sender header block, a rule, a blank line, then the raw body.
     *
     * <pre>
     * From: Muhammad Haris &lt;muhammad.haris@example.com&gt;
     * Subject: Gordon Center - Jacksonville FL
     * ------------------------------------------------------------
     *
     * &lt;raw email body, verbatim&gt;
     * </pre>
     *
     * ═══ WHY THIS BLOCK EXISTS ALONGSIDE THE SUBJECT PREFIX ═══
     * The prefix shares the 255-character Subject budget, so a long subject can lose its tail
     * there. The `Subject:` line here carries the original UNABRIDGED and is what makes that
     * trade safe. The `From:` line adds the ADDRESS, which the Subject deliberately has no room
     * for.
     *
     * ═══ THE `From:` LINE — ALWAYS EMITTED, FOUR SHAPES ═══
     *   • name + address → `Jane Broker &lt;jane@firm.com&gt;`
     *   • name only      → `Jane Broker`
     *   • address only   → `jane@firm.com`
     *   • neither        → SENDER_UNKNOWN. The line is still written: "the pipeline could not
     *     identify a sender" is itself information, and an omitted line reads as an oversight.
     *
     * ⚠ THE ADDRESS IS SHOWN VERBATIM AND IS **NOT** RUN THROUGH
     * InboundEmailFieldUtil.sanitizeEmail. That helper returns NULL for anything malformed,
     * which here would HIDE information rather than protect anything: Description is a text
     * field, so it cannot throw INVALID_EMAIL_ADDRESS, and `extraction.brokerEmail` travels
     * unsanitised by contract — so on the rare paste-forward path this slot may hold a display
     * name or a fragment. That is a useful signal to the reader (the extraction is suspect), and
     * it is bounded by the LEN_SENDER_EMAIL clip.
     *
     * ═══ COMPOSE-THEN-CLIP, SAME HEAD-PRESERVING RULE AS buildSubject ═══
     * The whole string is clipped to LEN_DESCRIPTION (32,000) ONCE, at the end, so the header
     * always survives and the BODY'S TAIL is what is lost at the ceiling. Two consequences,
     * both accepted deliberately:
     *   • a body that previously filled all 32,000 characters now loses roughly the header's
     *     length from its tail. The raw body survives verbatim on
     *     `Inbound_Email_Staging__c.Raw_Body__c`, which is the durable copy;
     *   • A NULL OR EMPTY BODY NOW YIELDS A DESCRIPTION CONTAINING JUST THE HEADER, where it
     *     previously yielded null. That is a behaviour change and an improvement — the sender is
     *     recorded even for an empty-bodied email.
     *
     * @param senderName  The broker's display name; may be blank.
     * @param senderEmail The broker's address; may be blank.
     * @param subject     The original inbound subject; blank yields SUBJECT_FALLBACK.
     * @param body        The raw email body; null or blank yields a header-only Description.
     * @return The composed Description, never longer than LEN_DESCRIPTION and never null.
     */
    private static String buildDescription(String senderName, String senderEmail,
                                           String subject, String body) {
        String name = String.isBlank(senderName) ? null : senderName.trim();
        String address = String.isBlank(senderEmail)
            ? null
            : InboundEmailFieldUtil.clip(senderEmail.trim(), LEN_SENDER_EMAIL);

        String fromValue;
        if (name != null && address != null) {
            fromValue = name + ' <' + address + '>';
        } else if (name != null) {
            fromValue = name;
        } else if (address != null) {
            fromValue = address;
        } else {
            fromValue = SENDER_UNKNOWN;
        }

        // 'From: ' / 'Subject: ' here are the RFC-shaped header labels — NOT
        // SUBJECT_SENDER_PREFIX, which is 'From ' with the colon deferred to after the name.
        String header = 'From: ' + fromValue + '\n'
            + 'Subject: ' + (String.isBlank(subject) ? SUBJECT_FALLBACK : subject) + '\n'
            + HEADER_RULE + '\n';

        // Explicit null guard: Apex renders a null operand of a String concatenation as the
        // literal text 'null', which would print `null` where the body belongs.
        String rawBody = (body == null) ? '' : body;

        return InboundEmailFieldUtil.clip(header + '\n' + rawBody, LEN_DESCRIPTION);
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
