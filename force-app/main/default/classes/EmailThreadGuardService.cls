/**
 * EAC THREAD GUARD — cleans up Einstein Activity Capture's address-based
 * over-association on Leads. This class owns the keep/delete DECISION and the only
 * DESTRUCTIVE DML in the capture pipeline; EmailCaptureQueueable is a thin async
 * wrapper that runs the adopter and then run() below, and EmailMessageTriggerHandler
 * only decides whether to enqueue it.
 *
 * ⚠ THE GUARD RUNS SECOND, AFTER EmailThreadAdopterService (2026-08-02). That order is
 * load-bearing: an Opportunity-anchored capture related only to an unrelated
 * same-address Lead would be deleted here before the adopter ever saw it (finding P6).
 * Because run() re-reads the messages, it observes the `RelatedToId` the adopter just
 * wrote and keeps such a row through the widened guard 4 below.
 *
 * ═══ THE PROBLEM ═══
 * EAC associates captured emails by ADDRESS MATCHING ONLY — it is completely
 * THREAD-BLIND. It attaches every email to every record whose address appears on it.
 * So when an agent sends a broker a brand-new, unrelated email from the connected
 * mailbox, EAC staples it onto that broker's deal Lead (and onto every other Lead
 * carrying that address), polluting the deal timeline with conversations that have
 * nothing to do with the deal.
 *
 * NO EAC CONFIGURATION CAN PREVENT THIS. There is no per-thread setting and no
 * relevance filter — only all-or-nothing per address. The fix therefore runs AFTER
 * capture: let EAC materialize the email, then DELETE IT FROM SALESFORCE when it
 * belongs to no thread the pipeline anchored on the Lead AND lives on no record
 * outside this guard's scope. Replies inside a deal thread stay; unrelated new
 * conversations vanish within seconds.
 *
 * ⚠ "DELETE IT FROM SALESFORCE", NOT "REMOVE IT FROM THE LEAD" — the wording matters
 * and was corrected 2026-08-02 (review W1). The trigger CONDITION is Lead-scoped but
 * the REMEDY is not: deleting an EmailMessage removes it from every record it was
 * associated with. That asymmetry is the whole reason scope guard 2 below exists.
 *
 * ═══ THE RULE ═══
 * An EAC-materialized email may stay on a Lead ONLY IF its `ThreadIdentifier` (or
 * `MessageIdentifier`) matches a THREAD ANCHOR the Broker Protection pipeline logged
 * on that Lead — `Task.Thread_Key__c` (conversation root) or
 * `Task.Inbound_Message_Id__c` (that message's own id), both stamped by
 * InboundEmailActivityService. Verified in real data: a genuine reply carries
 * ThreadIdentifier = the broker's original Message-ID (= the anchor); an unrelated
 * new conversation carries its own fresh id (no anchor). Anything unanchored is
 * deleted together with its companion timeline Task — UNLESS it lives elsewhere.
 *
 * ═══ SCOPE GUARDS — it only ever deletes when ALL FOUR of these hold ═══
 *   1. the EmailMessage is related to at least one LEAD (EmailMessageRelation),
 *   2. it is related to NO record outside {Lead, User} — see "LIVES ELSEWHERE" below,
 *   3. its companion Task (reached via EmailMessage.ActivityId) was created by the
 *      Automated Process user — the EAC materialization fingerprint,
 *   4. no related Lead carries a matching thread anchor.
 *
 * ═══ 🔴 GUARD 2 — "LIVES ELSEWHERE", AND WHY `User` IS EXCLUDED FROM IT ═══
 * Added 2026-08-02 (review W1). A capture EAC stapled to BOTH a Contact and a Lead was
 * previously judged solely on the Lead and, if unanchored there, deleted — taking it
 * off the CONTACT's timeline too, a record this feature explicitly declares out of
 * scope. That is not hypothetical here: the same brokers exist as Contacts
 * (Broker_Assignment__c / Lease_Inquiry__c) and as Leads (Broker Protection), and EAC
 * matches by address, so one captured email routinely lands on both.
 *
 * The rule is therefore "only delete captures that live nowhere else", and the
 * classification of `RelationObjectType` is deliberate:
 *
 *   • `Lead`  — the in-scope object. Never counts as living elsewhere; deciding about
 *               Leads IS this guard's job.
 *   • `User`  — EXCLUDED, and this exclusion is load-bearing. EAC writes a User
 *               relation for the mailbox participants (sender and internal recipients)
 *               on essentially EVERY capture. Counting User as "lives elsewhere" would
 *               make guard 2 true for every message the guard ever sees, and the
 *               feature would silently delete NOTHING, forever — a dead guard that
 *               still passes a naive smoke test. A User relation also is not a
 *               curated CRM timeline: it records who sent/received the mail, not a
 *               subject record whose activity history anyone maintains.
 *   • anything else (`Contact`, `Account`, `Opportunity`, `Case`, …) — COUNTS as
 *               living elsewhere. The capture is kept.
 *
 * The set below is an ALLOW-LIST of ignorable types, NOT a deny-list of protected
 * ones, and that direction is chosen for safety: an object type nobody anticipated
 * falls through to "lives elsewhere" and the capture is KEPT. A deny-list naming
 * Contact would fail OPEN — a future Account or Opportunity association would silently
 * become deletable.
 *
 * ═══ 🔴 WHY BROKER PROTECTION'S OWN TASKS CAN NEVER BE DELETED (structural) ═══
 * This guard has exactly ONE route to a Task: the Id stamped on
 * `EmailMessage.ActivityId`, read through TaskSelector.selectByIds. It never queries
 * Tasks by WhoId, Subject, or anchor value for deletion purposes — the anchor read
 * (EmailThreadAnchorService, via selectThreadAnchorsByAnchorValues) feeds the KEEP
 * decision and its rows are never added
 * to a delete list.
 *
 * Broker Protection's pipeline Tasks are created directly by
 * InboundEmailActivityService and are linked to NO EmailMessage whatsoever, so no
 * EmailMessage.ActivityId can ever point at one. The thread anchors this whole
 * feature depends on are therefore OUT OF REACH BY CONSTRUCTION, not by convention —
 * there is no data state, no ordering, and no future EAC behavior that makes a
 * pipeline anchor a deletion candidate. Proven by
 * EmailThreadGuardServiceTest.pipelineAnchorTaskIsStructurallyUnreachable. If a
 * future change ever adds a second way to reach a Task, that guarantee dies with it.
 *
 * ═══ HARD-WON GOTCHAS (source-org debugging; do not rediscover them) ═══
 *   1. `EmailMessage.ActivityId` IS SYSTEM-WRITABLE ONLY. Tests cannot set it — and
 *      do not need to: Enhanced Email auto-creates the companion Task on insert and
 *      stamps ActivityId. Re-read the record after insert to pick it up. (The test
 *      helper asserts ActivityId != null so the suite fails LOUD, not vacuously, if
 *      Enhanced Email is ever switched off.)
 *   2. THE AUTOMATEDPROCESS FINGERPRINT CANNOT BE REPRODUCED IN TESTS — test-created
 *      Tasks are owned by the running user. Hence the `treatAllAsMaterialized` seam
 *      below. It is the only way to exercise the delete path at all.
 *   3. THE MESSAGE AND TASK DELETES CASCADE INTO EACH OTHER. EAC links them, so a
 *      hard `delete` throws ENTITY_IS_DELETED on the second one. Use
 *      `Database.delete(..., false)` and treat an already-gone row as SUCCESS.
 *   4. THE TRIGGER MUST BE ASYNC. `EmailMessageRelation` rows are inserted AFTER the
 *      EmailMessage within the same transaction, so checking associations inside the
 *      trigger itself would see none and conclude "not Lead-related" for every
 *      capture. The queueable hop is load-bearing, not stylistic.
 *   5. DELIBERATE SENDS ARE DISTINGUISHABLE. Composer/Agentforce emails have a
 *      companion Task created by a REAL USER; EAC-materialized ones by AUTOMATED
 *      PROCESS. Guarding on `CreatedBy.UserType == 'AutomatedProcess'` means an
 *      intentional log is never touched.
 *   6. DELETED EMAILS ARE REMOVED FROM SALESFORCE ENTIRELY (they still exist in the
 *      mailbox). If EAC re-syncs one, the trigger fires again and the guard
 *      re-deletes it — the guard is SELF-HEALING, and re-running it is always safe.
 *   7. SCOPE IS LEADS ONLY, BY DESIGN — and as of 2026-08-02 (review W1) the CODE
 *      finally matches that claim. The guard only ever JUDGES a capture by the Leads
 *      it landed on, and it only DELETES a capture that relates to no record outside
 *      {Lead, User}; anything also living on a Contact / Account / Opportunity / Case
 *      is left alone, because deleting it would prune a timeline this feature has no
 *      mandate over (see "LIVES ELSEWHERE" above). Before this fix the condition was
 *      Lead-scoped but the remedy was org-wide — the claim was true of the trigger and
 *      false of the effect.
 *      To extend the guard to Contacts/Opportunities later: give those objects thread
 *      anchors FIRST, then admit their RelationObjectType into the judged set. Doing
 *      it in the other order makes every capture there look unanchored and deletes
 *      legitimate correspondence.
 *
 * ═══ LAYER / SHARING ═══
 * Service (ARCHITECTURE.md §2). All SOQL delegates to EmailMessageSelector,
 * EmailMessageRelationSelector and TaskSelector; this class contains none.
 *
 * `without sharing` justification (ARCHITECTURE.md §2 standard; precedent:
 * ApprovalAuditService, BrokerPortalService): the guard is a platform-hygiene
 * operation running in a wholly automated context, as whichever principal EAC
 * committed under — never as a human with a considered view of these records. It
 * must remove EAC's over-association from EVERY Lead the capture landed on, not just
 * the subset that principal happens to have sharing to. Under `with sharing` a Lead
 * outside that principal's sharing would silently keep the polluted timeline entry,
 * producing exactly the half-cleaned, unauditable state this feature exists to
 * prevent. The elevated scope is narrow and one-directional: it can only DELETE
 * platform-created EAC artifacts that satisfy all four scope guards above, and it
 * reads no business data.
 *
 * ═══ DML MODEL — plain `Database.delete` (system mode). READ THIS BEFORE "FIXING" IT ═══
 * `AccessLevel.USER_MODE` is intentionally NOT applied, matching the established module
 * pattern (`EmailToLeadService`, `InboundEmailStagingService`, `PropertyClaimService`).
 * PMD's `ApexCRUDViolation` flags both deletes below; the finding is **accepted, not
 * overlooked**, on the same grounds the sibling services record:
 *
 *   • There is no interactive user whose FLS/CRUD is meaningful to enforce. The running
 *     principal is whichever automated identity EAC committed under, and it holds none
 *     of this org's permission sets — USER_MODE would not "enforce a user's intent",
 *     it would abort the cleanup for everyone.
 *   • A DESTRUCTIVE system-mode DML does not inherit a read's justification, so the
 *     blast radius is closed BY CONSTRUCTION rather than by permissions: the only rows
 *     this class can ever delete are EmailMessages that satisfy all FOUR scope guards,
 *     plus the companion Task each one names through `ActivityId`. Nothing else is
 *     reachable (see the structural note above).
 *   • Because the delete is org-wide in effect, guard 2 ("lives nowhere else") is part
 *     of that blast-radius argument, not a nicety: without it a system-mode delete
 *     reaches records the feature never claimed. See "LIVES ELSEWHERE" above for the
 *     RelationObjectType classification and the `User` exclusion rationale.
 *   • `allOrNone = false` is required for correctness, not tolerance — see `purge`.
 *
 * This project has no `UnitOfWork` class (verified 2026-07-24), so service-layer DML is
 * direct by convention.
 *
 * ═══ BULK / GOVERNOR SHAPE — NOT covered by the singleton exemption ═══
 * .claude/rules/bulk-test-rule.md's per-transaction-singleton exemption does NOT
 * apply here, and the reasoning must not be re-litigated: this class is
 * TRIGGER-DRIVEN and EAC BATCH-INSERTS its captures, so `run()` legitimately
 * receives hundreds of message Ids in one transaction. Every read is one bulk query
 * over the whole set and both deletes are single bulk DML — there is no per-record
 * SOQL or DML anywhere. The 251-record test in EmailThreadGuardServiceTest is what
 * keeps it that way.
 *
 * @see EmailCaptureQueueable.cls (thin async wrapper — adopter, then this)
 * @see EmailThreadAdopterService.cls (the mirror half; runs BEFORE this one)
 * @see EmailMessageTriggerHandler.cls / triggers/EmailMessageTrigger.trigger
 * @see InboundEmailActivityService.cls (writes the anchors this guard matches on)
 * @see agent-output/change-prompts-broker-protection-2026-07-31.md (Change Prompt 2)
 */
public without sharing class EmailThreadGuardService {

    /** `CreatedBy.UserType` of the companion Task EAC materializes. The fingerprint. */
    private static final String USER_TYPE_AUTOMATED_PROCESS = 'AutomatedProcess';

    /** `EmailMessageRelation.RelationObjectType` for the one object this guard judges. */
    private static final String RELATION_OBJECT_TYPE_LEAD = 'Lead';

    /**
     * RelationObjectTypes that do NOT count as "this capture lives elsewhere" (guard 2).
     *
     * ⚠ ALLOW-LIST, NOT A DENY-LIST — an unanticipated object type falls through to
     * "lives elsewhere" and the capture is KEPT. Full rationale, including why `User`
     * must be in here or the guard deletes nothing forever, is in the class header
     * under "LIVES ELSEWHERE". Do not add a type here without reading it.
     */
    private static final Set<String> RELATION_TYPES_NOT_LIVING_ELSEWHERE = new Set<String>{
        RELATION_OBJECT_TYPE_LEAD, 'User'
    };

    /**
     * TEST SEAM — see gotcha 2. Companion Tasks created in tests are owned by the
     * running user, so the AutomatedProcess fingerprint can never be reproduced in a
     * test context. Setting this treats every candidate as EAC-materialized, which is
     * the only way to exercise the delete path.
     *
     * Deliberately NOT a permission, a custom setting, or anything reachable at
     * runtime: production behavior must depend solely on the real fingerprint.
     */
    @TestVisible
    private static Boolean treatAllAsMaterialized = false;

    /**
     * Examine captured emails and remove the ones that belong to no thread anchored on
     * the Lead(s) they landed on. Idempotent and safe to re-run over the same Ids —
     * already-deleted rows simply drop out of the initial read (gotcha 6).
     *
     * Entry point for the one-off backfill sweep of already-materialized noise
     * (anonymous Apex, run by DevOps post-UAT — see the change prompt §5.3). The live
     * path is EmailCaptureQueueable, which calls the two-argument overload below so the
     * anchor read is shared with the adopter.
     *
     * ⚠ SWEEP ORDER IS ADOPTER → GUARD. Running this sweep first over a historical window
     * deletes captures the adopter would have rescued, and a deleted EmailMessage is not
     * recoverable in Salesforce.
     *
     * @param messageIds EmailMessage Ids to examine; null/empty is a no-op.
     * @example
     * EmailThreadGuardService.run(new Map<Id, EmailMessage>(
     *     [SELECT Id FROM EmailMessage WHERE CreatedDate = LAST_N_DAYS:7]).keySet());
     */
    public static void run(Set<Id> messageIds) {
        run(messageIds, null);
    }

    /**
     * The queueable entry point: identical semantics, but consuming the SHARED anchor index
     * the adopter already built (D3) so the anchor read happens ONCE per execution rather
     * than once per feature.
     *
     * Passing null is legal and is what the sweep path does — the index is then built here.
     * That is why the one-argument `run(Set&lt;Id&gt;)` above is unchanged and why all twelve
     * existing guard tests call it without modification.
     *
     * @param messageIds  EmailMessage Ids to examine; null/empty is a no-op.
     * @param sharedIndex The pre-built anchor index, or null to build one.
     */
    public static void run(Set<Id> messageIds, EmailThreadAnchorService.AnchorIndex sharedIndex) {
        if (messageIds == null || messageIds.isEmpty()) {
            return;
        }
        List<EmailMessage> messages = EmailMessageSelector.selectByIds(messageIds);
        if (messages.isEmpty()) {
            return;
        }
        EmailThreadAnchorService.AnchorIndex anchors = (sharedIndex != null)
            ? sharedIndex
            : EmailThreadAnchorService.index(messages);

        // ONE read of every association EAC created, indexed two ways: the Leads each
        // message landed on (guard 1) and whether it also lives on an out-of-scope
        // record (guard 2). Nothing Lead-shaped means nothing this guard is responsible
        // for — user-to-user mail and Contact-only captures exit here untouched.
        RelationIndex relations = indexRelations(messageIds);
        if (relations.leadIdsByMessageId.isEmpty()) {
            return;
        }

        Map<Id, Task> companionsByTaskId = companionTasks(messages);

        List<EmailMessage> doomedMessages = new List<EmailMessage>();
        List<Task> doomedTasks = new List<Task>();
        for (EmailMessage message : messages) {
            Set<Id> relatedLeadIds = relations.leadIdsByMessageId.get(message.Id);
            Task companion = companionFor(message, companionsByTaskId);
            // The four scope guards, in the order that makes each cheap to reason about.
            // Anything ambiguous falls through to `continue` — never delete on a maybe.
            if (relatedLeadIds == null                                  // 1: landed on no Lead
                || relations.messagesLivingElsewhere.contains(message.Id) // 2: lives elsewhere
                || !isEacMaterialized(companion)                        // 3: a deliberate send
                || isAnchoredAnywhere(message, relatedLeadIds, anchors)) { // 4: anchored reply
                continue;
            }
            doomedMessages.add(new EmailMessage(Id = message.Id));
            if (companion != null) {
                doomedTasks.add(new Task(Id = companion.Id));
            }
        }
        purge(doomedTasks, doomedMessages);
    }

    /**
     * The companion Task a capture names through `ActivityId` — the single route this
     * class has to any Task.
     *
     * @param message            The capture under examination.
     * @param companionsByTaskId Companion Tasks keyed by Task Id.
     * @return The companion Task, or null when the capture names none.
     */
    private static Task companionFor(EmailMessage message, Map<Id, Task> companionsByTaskId) {
        return (message.ActivityId == null) ? null : companionsByTaskId.get(message.ActivityId);
    }

    /**
     * The two facts the decision needs from EAC's association rows, read once.
     * `leadIdsByMessageId` drives guard 1 and the anchor lookup; `messagesLivingElsewhere`
     * drives guard 2.
     */
    private class RelationIndex {
        private Map<Id, Set<Id>> leadIdsByMessageId = new Map<Id, Set<Id>>();
        private Set<Id> messagesLivingElsewhere = new Set<Id>();
    }

    /**
     * Indexes EAC's associations for the captures under examination: which Leads each
     * one landed on, and which ones ALSO landed on a record outside {Lead, User}.
     *
     * ⚠ Both answers come from ONE query and ONE pass (review W1). Reading Leads and
     * non-Leads separately would double the query cost on an EAC batch and let the two
     * answers disagree — and a disagreement here deletes correspondence off a record
     * the feature never claimed.
     *
     * The `else if` is deliberate: a Lead relation must never also mark the message as
     * living elsewhere, or guard 2 would veto every deletion the guard exists to make.
     *
     * @param messageIds The captured emails under examination.
     * @return The index; both members are empty when the messages matched nothing
     *         (never null).
     */
    private static RelationIndex indexRelations(Set<Id> messageIds) {
        RelationIndex index = new RelationIndex();
        for (EmailMessageRelation relation
                : EmailMessageRelationSelector.selectByMessageIds(messageIds)) {
            if (RELATION_OBJECT_TYPE_LEAD.equals(relation.RelationObjectType)) {
                if (!index.leadIdsByMessageId.containsKey(relation.EmailMessageId)) {
                    index.leadIdsByMessageId.put(relation.EmailMessageId, new Set<Id>());
                }
                index.leadIdsByMessageId.get(relation.EmailMessageId).add(relation.RelationId);
            } else if (!RELATION_TYPES_NOT_LIVING_ELSEWHERE.contains(relation.RelationObjectType)) {
                index.messagesLivingElsewhere.add(relation.EmailMessageId);
            }
        }
        return index;
    }

    /**
     * Loads the companion Tasks the platform linked via EmailMessage.ActivityId — the
     * carriers of the EAC fingerprint, and the ONLY Tasks this class can ever delete
     * (see the class header's structural-unreachability note).
     *
     * @param messages The captured emails under examination.
     * @return Companion Tasks (Id, CreatedBy.UserType) keyed by Task Id; empty when
     *         no message carries an ActivityId (never null).
     */
    private static Map<Id, Task> companionTasks(List<EmailMessage> messages) {
        Set<Id> taskIds = new Set<Id>();
        for (EmailMessage message : messages) {
            if (message.ActivityId != null) {
                taskIds.add(message.ActivityId);
            }
        }
        return new Map<Id, Task>(TaskSelector.selectByIds(taskIds));
    }

    /**
     * Scope guard 2 (gotchas 2 and 5): is this capture EAC's own work rather than a
     * deliberate composer/Agentforce send? A message with no companion Task at all
     * fails closed — it is NOT treated as materialized, so nothing is deleted.
     *
     * `companion.CreatedBy` is dereferenced without a null check on purpose: the only
     * source of a companion Task is TaskSelector.selectByIds, which selects
     * `CreatedBy.UserType`, and CreatedById is a system field that is never null on a
     * queried row. Presence is guaranteed, so a guard here would be dead code.
     *
     * @param companion The companion Task, or null when the message carries none.
     * @return true when the companion was created by the Automated Process user, or
     *         when the test seam is engaged.
     */
    private static Boolean isEacMaterialized(Task companion) {
        if (treatAllAsMaterialized) {
            return true;
        }
        return companion != null
            && USER_TYPE_AUTOMATED_PROCESS.equals(companion.CreatedBy.UserType);
    }

    /**
     * Scope guard 3: does ANY related Lead anchor this message's thread? One anchored
     * Lead is enough to keep the message everywhere — the guard removes an email from
     * Salesforce entirely (gotcha 6), so it must never delete a message that is
     * legitimate on even one of its Leads.
     *
     * ⚠ This is also what makes the guard correct after Change 1 (competing brokers
     * get no Lead of their own): a WINNING Lead accumulates anchors for SEVERAL
     * brokers' threads, and a reply in any of them is legitimate on that Lead.
     *
     * ⚠ WIDENED 2026-08-02 (finding P6) — from "anchored on a related LEAD" to "anchored on
     * ANY record it lives on": the related Leads **∪** the `RelatedToId` record. This change
     * is STRICTLY KEEP-BIASED — it can only ever cause the guard to delete FEWER messages,
     * never more — and it is what stops the guard destroying the adopter's output. An
     * adopted capture is anchored on its Opportunity, not on any Lead; before this widening
     * the guard could not see `RelatedToId` at all and would delete it seconds later.
     *
     * ⚠ Matching now runs through the SHARED index, which normalizes brackets on both sides.
     * That fixes the live defect P4/E3: the old comparison tested raw EAC identifiers
     * (bracketed) against `Thread_Key__c` (stored unbracketed), so the ThreadIdentifier leg
     * could never match and the guard ran on one leg only.
     *
     * @param message        The capture under examination.
     * @param relatedLeadIds Leads EAC associated it with.
     * @param anchors        The shared anchor index.
     * @return true when ANY record this capture lives on carries a matching anchor.
     */
    private static Boolean isAnchoredAnywhere(
            EmailMessage message, Set<Id> relatedLeadIds,
            EmailThreadAnchorService.AnchorIndex anchors) {
        for (Id leadId : relatedLeadIds) {
            if (anchors.isAnchoredOn(leadId, message)) {
                return true;
            }
        }
        return anchors.isAnchoredOn(message.RelatedToId, message);
    }

    /**
     * Deletes the doomed rows: Tasks first, then messages, each as ONE bulk DML.
     *
     * ⚠ `allOrNone = false` IS DELIBERATE (gotcha 3), not defensive noise. EAC links a
     * message and its companion Task, so the first delete can cascade into the second
     * — which then finds its row already gone. That is SUCCESS, not failure; a hard
     * `delete` would throw ENTITY_IS_DELETED and abort the whole sweep, leaving the
     * remaining captures unexamined. Failures are logged rather than thrown for the
     * same reason: one stubborn row must not stop the guard cleaning the rest.
     *
     * ⚠ TWO ACCEPTED STATIC-ANALYSIS FINDINGS LIVE ON THESE FOUR LINES, both deliberate:
     *   • `ApexCRUDViolation` — plain (system-mode) DML. Justified in the class header
     *     under DML MODEL; USER_MODE here would disable the guard, not secure it.
     *   • `AvoidDebugStatements` — this repo has no logging framework, and these are
     *     ERROR paths reached only when a delete genuinely fails, not main-path
     *     instrumentation. Silently swallowing a `DeleteResult` failure is the one
     *     outcome that would leave a polluted timeline with nothing to explain it.
     *     Same posture as `PropertyClaimService` on its fail-safe path.
     *
     * @param doomedTasks    Companion Tasks to remove; empty-safe.
     * @param doomedMessages Captured emails to remove; empty-safe.
     */
    private static void purge(List<Task> doomedTasks, List<EmailMessage> doomedMessages) {
        if (!doomedTasks.isEmpty()) {
            for (Database.DeleteResult result : Database.delete(doomedTasks, false)) {
                if (!result.isSuccess()) {
                    System.debug(LoggingLevel.WARN, 'EAC guard task delete: ' + result.getErrors());
                }
            }
        }
        if (!doomedMessages.isEmpty()) {
            for (Database.DeleteResult result : Database.delete(doomedMessages, false)) {
                if (!result.isSuccess()) {
                    System.debug(LoggingLevel.WARN, 'EAC guard message delete: ' + result.getErrors());
                }
            }
        }
    }
}
