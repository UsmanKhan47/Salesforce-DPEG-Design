/**
 * Tests for EmailThreadGuardService — the EAC Thread Guard decision layer.
 *
 * ═══ WHY THE 251-RECORD MANDATE APPLIES HERE (and the singleton exemption does NOT) ═══
 * `.claude/rules/bulk-test-rule.md` exempts per-transaction-singleton async pipelines.
 * THIS CLASS IS NOT ONE, and the reasoning must not be re-litigated at review:
 * `EmailThreadGuardService.run` is TRIGGER-DRIVEN, and Einstein Activity Capture
 * BATCH-INSERTS its captures on its own schedule. Hundreds of message Ids in one
 * transaction is the normal case, not a contrived one — the volume is set by an
 * external system nothing in this org controls. `guardAt251Captures_isBulkSafe` below
 * is therefore a literal 251, produced the way production produces it: ONE bulk
 * EmailMessage insert, ONE `run()` call. It exists to make any future per-record SOQL
 * or DML fail HERE rather than in a live EAC batch.
 *
 * ═══ WHY EVERY DELETE TEST SETS `treatAllAsMaterialized` ═══
 * The EAC fingerprint (`companion Task.CreatedBy.UserType == 'AutomatedProcess'`)
 * CANNOT be reproduced in a test — Tasks created in a test are owned by the running
 * user. The seam is the only way to reach the delete path at all. Tests that assert
 * something is KEPT because it is a deliberate send deliberately leave the seam OFF.
 *
 * ═══ A NOTE ON THE ActivityId ASSERTION IN makeCapturedEmail ═══
 * The whole suite rests on Enhanced Email auto-creating the companion Task and
 * stamping `EmailMessage.ActivityId` on insert (verified live in `usman-dpeg`
 * 2026-08-02). If Enhanced Email is ever disabled, every companion would be null, the
 * guard would find nothing to fingerprint, and these tests would pass VACUOUSLY while
 * the feature was dead. The helper asserts ActivityId is populated so that failure is
 * LOUD and lands on the precondition rather than on a downstream assertion.
 *
 * ═══ THE W1 PAIR IS THE ONE TO READ FIRST IF YOU CHANGE SCOPE ═══
 * `captureAlsoLivingOnAContactIsKept` and `captureLivingOnlyOnLeadAndUserIsStillDeleted`
 * fail in OPPOSITE directions and only mean something together: the first breaks if
 * scope guard 2 is dropped, the second breaks if `User` is admitted to it. A change
 * that satisfies only one of them has broken the feature in one of its two possible
 * ways — deleting other teams' correspondence, or deleting nothing at all.
 *
 * ASSERTION STYLE: Assert.* — matches the sibling Broker-Protection test classes.
 *
 * @see EmailThreadGuardService.cls (the seven gotchas and the four scope guards)
 * @see EmailMessageTriggerHandlerTest.cls (trigger → handler → queueable path)
 */
@isTest
private class EmailThreadGuardServiceTest {

    private static final String DEAL_ROOT = 'root@deal.example.invalid';
    private static final String NEW_CONVO = 'new-convo@mail.example.invalid';

    // ─────────────────────────────────────────────────────────────────────────
    // Provided tests (Change Prompt 2 §3.3) — intent preserved verbatim
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The core case the feature exists for: the agent starts a brand-new, unrelated
     * conversation with a broker, EAC staples it onto that broker's deal Lead, and the
     * guard removes it because no anchor on that Lead matches its thread.
     */
    @isTest
    static void unanchoredEmailIsRemovedFromLead() {
        Lead broker = makeLead();
        // The Lead deal thread is DEAL_ROOT; the captured email is a NEW thread.
        insert anchorTask(broker.Id, DEAL_ROOT);
        EmailMessage noise = makeCapturedEmail(broker.Id, NEW_CONVO, NEW_CONVO);
        Id companionId = noise.ActivityId;

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ noise.Id });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM EmailMessage WHERE Id = :noise.Id],
            'An email from a thread no anchor on this Lead knows must be removed');
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE Id = :companionId],
            'Its companion timeline Task must be removed too, or the timeline stays polluted');
    }

    /**
     * The inverse, and the reason the guard cannot simply delete everything EAC
     * captures: a genuine reply inside the deal thread carries ThreadIdentifier = the
     * anchored root and must survive.
     */
    @isTest
    static void threadReplyIsKept() {
        Lead broker = makeLead();
        insert anchorTask(broker.Id, DEAL_ROOT);
        EmailMessage reply = makeCapturedEmail(broker.Id, DEAL_ROOT, 'reply-1@mail.example.invalid');
        Id companionId = reply.ActivityId;

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ reply.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM EmailMessage WHERE Id = :reply.Id],
            'A reply within the anchored deal thread must stay on the Lead');
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE Id = :companionId],
            'Its companion timeline Task must stay too');
    }

    /**
     * GAP CLOSED (unit-testing agent pass, 2026-08-02). `isAnchored` matches on
     * `message.ThreadIdentifier OR message.MessageIdentifier` — EVERY test above that
     * proves a keep decision does so via the ThreadIdentifier half alone (in each,
     * ThreadIdentifier equals the anchor and MessageIdentifier does not). Deleting the
     * `|| anchors.contains(message.MessageIdentifier)` term outright would not fail a
     * single one of them. This test isolates the second half: the capture's
     * ThreadIdentifier matches NOTHING anchored, and only its MessageIdentifier equals
     * a value the pipeline anchored (Task.Inbound_Message_Id__c on a reply-anchor,
     * where Thread_Key__c is the thread root but Inbound_Message_Id__c is that
     * message's own, different, id — see EmailMessageSelector's class header: "a
     * thread root's ThreadIdentifier IS its own MessageIdentifier, and the pipeline
     * anchors that root under Inbound_Message_Id__c").
     */
    @isTest
    static void anchorMatchViaMessageIdentifierAloneIsKept() {
        Lead broker = makeLead();
        // A reply-anchor Task: Thread_Key__c is the thread ROOT, Inbound_Message_Id__c is
        // THIS message's own (different) id — the shape a second message in a thread
        // produces, distinct from anchorTask()'s root shape where both keys match.
        String replyOwnId = 'anchored-reply@mail.example.invalid';
        insert new Task(WhoId = broker.Id, Subject = 'Email: deal', Status = 'Completed',
                        TaskSubtype = 'Email', Thread_Key__c = DEAL_ROOT,
                        Inbound_Message_Id__c = replyOwnId);

        // EAC's ThreadIdentifier for this capture matches nothing anchored; only its
        // MessageIdentifier is a message the pipeline already anchored.
        EmailMessage capture = makeCapturedEmail(
            broker.Id, 'eac-unrelated-thread@mail.example.invalid', replyOwnId);

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ capture.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM EmailMessage WHERE Id = :capture.Id],
            'A capture must be kept when only its MessageIdentifier (not its ThreadIdentifier) '
            + 'matches an anchor — the OR\'s second term is load-bearing on its own, not merely '
            + 'redundant with the first');
    }

    /**
     * Scope guard 2. With the seam OFF the companion Task is created by the running
     * user, not Automated Process — the fingerprint of a deliberate composer or
     * Agentforce send. Such an email is never touched even with NO anchor at all,
     * which is what makes the guard safe to leave running on a live org.
     */
    @isTest
    static void deliberateSendIsNeverTouched() {
        Lead broker = makeLead();
        EmailMessage sent = makeCapturedEmail(broker.Id, 'composer@mail.example.invalid',
                                              'composer@mail.example.invalid');

        EmailThreadGuardService.treatAllAsMaterialized = false;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ sent.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM EmailMessage WHERE Id = :sent.Id],
            'Emails logged by a real user (composer / Agentforce) must never be deleted, '
            + 'even when nothing anchors them');
    }

    /**
     * Scope guard 1. Nothing Lead-shaped means nothing this guard is responsible for:
     * user-to-user mail, Contact-only and Case correspondence all exit untouched.
     */
    @isTest
    static void nonLeadEmailIsIgnored() {
        // Inserted WITHOUT a relation, and deliberately not through makeCapturedEmail:
        // the guard exits on scope guard 1 before it ever looks at a companion Task, so
        // asserting ActivityId here would test the platform rather than the guard.
        EmailMessage userToUser = buildCapture('x@mail.example.invalid', 'x@mail.example.invalid');
        insert userToUser;

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ userToUser.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM EmailMessage WHERE Id = :userToUser.Id],
            'An email related to no Lead is outside this guard scope and must survive');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Added per design decision C-8
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * ⚠ THE CASE CHANGE 1 CREATED. Since competing brokers no longer get a Lead of
     * their own, a WINNING Lead accumulates thread anchors for SEVERAL brokers
     * threads — its own broker plus every competing submission logged against it. A
     * capture matching a COMPETING broker thread is therefore legitimate on the
     * winning Lead and must be KEPT.
     *
     * Both messages go through ONE run() call so the contrast is proven inside a
     * single decision pass: the competing-broker reply survives while an unrelated
     * new conversation on the SAME Lead does not. A guard that kept both (or deleted
     * both) would pass a single-message test and fail this one.
     */
    @isTest
    static void competingBrokerThreadReplyIsKeptOnTheWinningLead() {
        Lead winner = makeLead();
        String brokerAThread = 'broker-a-root@deal.example.invalid';
        String brokerBThread = 'broker-b-root@deal.example.invalid';
        insert new List<Task>{
            anchorTask(winner.Id, brokerAThread),
            anchorTask(winner.Id, brokerBThread)
        };

        EmailMessage competingReply = makeCapturedEmail(
            winner.Id, brokerBThread, 'broker-b-reply@mail.example.invalid');
        EmailMessage unrelated = makeCapturedEmail(winner.Id, NEW_CONVO, NEW_CONVO);

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ competingReply.Id, unrelated.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM EmailMessage WHERE Id = :competingReply.Id],
            'A reply in a COMPETING broker thread is anchored on the winning Lead (Change 1 '
            + 'gives competing brokers no Lead of their own) and must be kept');
        Assert.areEqual(0, [SELECT COUNT() FROM EmailMessage WHERE Id = :unrelated.Id],
            'An unrelated new conversation on the SAME Lead must still be removed — '
            + 'one anchored thread must not whitelist every capture on that Lead');
    }

    /**
     * 🔴 THE SAFETY PROOF THIS FEATURE STANDS ON. The guard can only ever reach a Task
     * through `EmailMessage.ActivityId`. Broker Protection pipeline Tasks are created
     * by InboundEmailActivityService and are linked to NO EmailMessage, so no
     * ActivityId can point at one — they are out of reach BY CONSTRUCTION, not by
     * convention.
     *
     * This test runs a full deletion pass against a Lead whose ONLY other activity is
     * a pipeline anchor Task, and asserts the anchor survives while the capture and
     * its companion do not. If a future change ever adds a second route to a Task,
     * this goes red.
     */
    @isTest
    static void pipelineAnchorTaskIsStructurallyUnreachable() {
        Lead broker = makeLead();
        Task pipelineAnchor = anchorTask(broker.Id, DEAL_ROOT);
        insert pipelineAnchor;
        EmailMessage noise = makeCapturedEmail(broker.Id, NEW_CONVO, NEW_CONVO);
        Id companionId = noise.ActivityId;
        Assert.areNotEqual(pipelineAnchor.Id, companionId,
            'Precondition: the pipeline anchor and the EAC companion must be different Tasks, '
            + 'or this test proves nothing');

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ noise.Id });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM EmailMessage WHERE Id = :noise.Id],
            'The unanchored capture is deleted, so the guard did run a real deletion pass');
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE Id = :companionId],
            'Its companion Task — reachable via ActivityId — is deleted');
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE Id = :pipelineAnchor.Id],
            'The Broker Protection thread anchor on the SAME Lead survives: no '
            + 'EmailMessage.ActivityId points at it, so the guard can never reach it. '
            + 'Deleting anchors would silently disarm reply threading for the whole module');
    }

    /**
     * BULK SAFETY at the volume EAC actually produces. ONE bulk EmailMessage insert of
     * 251 rows (two trigger chunks), ONE run() call. Every read in the service is a
     * single query over the whole set and both deletes are single bulk DML — a
     * regression that reintroduces per-record SOQL or DML fails here, not in
     * production.
     *
     * All 251 are unanchored, so all 251 must be removed: a partial result would mean
     * the service dropped rows somewhere in its grouping.
     */
    @isTest
    static void guardAt251Captures_isBulkSafe() {
        final Integer volume = 251;
        Lead broker = makeLead();
        insert anchorTask(broker.Id, DEAL_ROOT);

        List<EmailMessage> captures = new List<EmailMessage>();
        for (Integer i = 0; i < volume; i++) {
            captures.add(buildCapture('bulk-' + i + '@mail.example.invalid',
                                      'bulk-' + i + '@mail.example.invalid'));
        }
        insert captures; // ONE bulk DML — the shape EAC uses.

        List<EmailMessageRelation> relations = new List<EmailMessageRelation>();
        for (EmailMessage capture : captures) {
            relations.add(new EmailMessageRelation(
                EmailMessageId = capture.Id, RelationId = broker.Id, RelationType = 'ToAddress'));
        }
        insert relations;

        Set<Id> captureIds = new Map<Id, EmailMessage>(captures).keySet();
        Set<Id> companionIds = new Set<Id>();
        for (EmailMessage requeried : [SELECT Id, ActivityId FROM EmailMessage WHERE Id IN :captureIds]) {
            if (requeried.ActivityId != null) {
                companionIds.add(requeried.ActivityId);
            }
        }
        Assert.areEqual(volume, companionIds.size(),
            'Precondition: Enhanced Email must stamp a companion Task on all ' + volume
            + ' captures, or the bulk delete path is not actually being exercised');

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(captureIds);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM EmailMessage WHERE Id IN :captureIds],
            'All ' + volume + ' unanchored captures must be removed in one pass — a partial '
            + 'result means rows were dropped between the grouping and the delete');
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE Id IN :companionIds],
            'All ' + volume + ' companion Tasks must be removed alongside their messages');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // W1 — SCOPE GUARD 2 ("lives elsewhere"). These two tests are a MATCHED PAIR and
    // discriminate in opposite directions; neither is meaningful without the other:
    //   • the Contact test goes RED if guard 2 is removed (the capture gets deleted),
    //   • the User test goes RED if `User` is ever counted as "lives elsewhere" (the
    //     capture gets kept, and with it every capture the guard will ever see —
    //     a silently dead feature that still passes the Contact test).
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 THE W1 DEFECT. The trigger condition is Lead-scoped but deleting an
     * EmailMessage removes it from Salesforce ENTIRELY — so a capture EAC stapled to a
     * Contact AND a Lead was judged only on the Lead and, if unanchored there, vanished
     * from the Contact's timeline too. That is a record this feature declares out of
     * scope, and it is a real shape in this org: the same brokers exist as Contacts
     * (Broker_Assignment__c / Lease_Inquiry__c) and as Leads (Broker Protection).
     *
     * Everything here is set up to make the guard WANT to delete — unanchored thread,
     * seam engaged, an anchored but unrelated thread present on the Lead. Only the
     * Contact relation stops it.
     */
    @isTest
    static void captureAlsoLivingOnAContactIsKept() {
        Lead broker = makeLead();
        Contact brokerContact = TestDataFactory.createBrokerContact(null, true);
        insert anchorTask(broker.Id, DEAL_ROOT);
        EmailMessage capture = makeCapturedEmail(broker.Id, NEW_CONVO, NEW_CONVO);
        relate(capture.Id, brokerContact.Id, 'ToAddress');
        // AFTER the Contact relation — it replaced the companion Task (see relate, fact 2).
        Id companionId = companionIdOf(capture.Id);

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ capture.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM EmailMessage WHERE Id = :capture.Id],
            'A capture that ALSO lives on a Contact must be kept even though it is unanchored on '
            + 'the Lead — deleting it would prune a timeline this feature has no mandate over. '
            + 'Remove scope guard 2 and this goes red');
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE Id = :companionId],
            'Its companion Task must survive too, or the Contact timeline loses the entry anyway');
    }

    /**
     * 🔴 THE COUNTERWEIGHT. EAC writes a `User` relation for the mailbox participants on
     * essentially every capture, so if `User` counted as "lives elsewhere" guard 2 would
     * be true for every message the guard ever sees and the feature would delete
     * NOTHING, forever — while still passing the Contact test above.
     *
     * Same setup as the Contact test, with the ubiquitous User relation in place of the
     * Contact one; the capture must still be deleted.
     */
    @isTest
    static void captureLivingOnlyOnLeadAndUserIsStillDeleted() {
        Lead broker = makeLead();
        insert anchorTask(broker.Id, DEAL_ROOT);
        EmailMessage capture = makeCapturedEmail(broker.Id, NEW_CONVO, NEW_CONVO);
        // 'CcAddress', not 'ToAddress'/'FromAddress' — see relate, fact 1. The guard reads
        // RelationObjectType (derived as 'User' either way), never RelationType, so this
        // seeds exactly the shape under test.
        relate(capture.Id, UserInfo.getUserId(), 'CcAddress');
        Id companionId = companionIdOf(capture.Id);

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ capture.Id });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM EmailMessage WHERE Id = :capture.Id],
            'A User relation must NOT count as "lives elsewhere". EAC puts one on nearly every '
            + 'capture, so counting it would disable the guard entirely while every other test '
            + 'stayed green');
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE Id = :companionId],
            'Its companion Task is removed with it, exactly as in the plain unanchored case');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Guard clauses / re-run safety
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Gotcha 6: the guard is self-healing, so re-running it over Ids whose rows are
     * already gone must be a silent no-op rather than an exception. This is the exact
     * shape of the one-off sweep re-run over a date window that overlaps a previous
     * sweep.
     */
    @isTest
    static void reRunOverAlreadyDeletedRows_isASilentNoOp() {
        Lead broker = makeLead();
        EmailMessage noise = makeCapturedEmail(broker.Id, NEW_CONVO, NEW_CONVO);
        Id captureId = noise.Id;

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ captureId });
        EmailThreadGuardService.run(new Set<Id>{ captureId }); // second pass, rows already gone
        EmailThreadGuardService.run(null);
        EmailThreadGuardService.run(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM EmailMessage WHERE Id = :captureId],
            'The first pass removes the capture and every later pass is a no-op — re-running '
            + 'the sweep over an overlapping window must never throw');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /** @return An inserted Lead standing in for a broker on a deal. */
    private static Lead makeLead() {
        return TestDataFactory.createLead(true);
    }

    /**
     * Adds one more EAC association to an already-captured email — the way a single
     * capture ends up on several records at once because their addresses all appear
     * on it.
     *
     * ⚠ TWO ORG FACTS MEASURED IN `usman-dpeg` 2026-08-02 (anonymous-Apex bisect), both
     * of which cost a failed deploy. Do not re-derive them from first principles:
     *
     * 1. **A `User` relation cannot use 'ToAddress' or 'FromAddress' when the message
     *    has `FromAddress` populated** — both throw
     *    `LIMIT_EXCEEDED, An email can't have more than 1 sender`. The platform
     *    auto-creates a FromAddress-typed relation for the sender address (with a NULL
     *    RelationId, hence a null RelationObjectType), and a User on the to/from slots
     *    collides with it. **'CcAddress' inserts cleanly** and was verified to derive
     *    `RelationObjectType = 'User'` all the same — which is the only field the guard
     *    reads. Non-User relations (Lead, Contact) are unaffected and use 'ToAddress'.
     * 2. **Adding a relation DESTROYS the existing companion Task and creates a new
     *    one.** Measured: ActivityId went 00T…F38r → 00T…F38s on the second relation,
     *    and only 1 of the 2 Task Ids still existed. So any ActivityId captured before
     *    the last relation is STALE — always read it through `companionIdOf` AFTER all
     *    relations are seeded.
     *
     * @param messageId    The captured EmailMessage.
     * @param recordId     The record EAC matched (Contact, User, …).
     * @param relationType Which address matched; see fact 1 for the User constraint.
     */
    private static void relate(Id messageId, Id recordId, String relationType) {
        insert new EmailMessageRelation(
            EmailMessageId = messageId, RelationId = recordId, RelationType = relationType);
    }

    /**
     * The CURRENT companion Task Id for a capture. Must be called after every relation
     * is in place — see `relate` fact 2: each new relation replaces the companion Task,
     * so an Id read earlier points at a row the platform has already deleted.
     *
     * @param messageId The captured EmailMessage.
     * @return Its companion Task Id.
     */
    private static Id companionIdOf(Id messageId) {
        Id companionId = [SELECT ActivityId FROM EmailMessage WHERE Id = :messageId].ActivityId;
        Assert.isNotNull(companionId,
            'PRECONDITION FAILED: the capture must have a companion Task once its relations exist '
            + '(Enhanced Email stamps ActivityId only when the message is associated with a record)');
        return companionId;
    }

    /**
     * An unsaved Broker-Protection pipeline thread anchor — the shape
     * InboundEmailActivityService writes. Both threading keys are set to the same
     * value, which is what a thread ROOT looks like.
     *
     * ⚠ Task.Type is deliberately absent and must stay absent: it does not exist in
     * this org, compiles anyway, and throws at runtime. See
     * InboundEmailActivityService header.
     *
     * @param leadId    The Lead the anchor sits on (Task.WhoId).
     * @param threadKey The conversation-root Message-ID.
     * @return The unsaved anchor Task.
     */
    private static Task anchorTask(Id leadId, String threadKey) {
        return new Task(
            WhoId = leadId,
            Subject = 'Email: deal',
            Status = 'Completed',
            TaskSubtype = 'Email',
            Thread_Key__c = threadKey,
            Inbound_Message_Id__c = threadKey
        );
    }

    /**
     * An unsaved EmailMessage in the shape EAC materializes.
     *
     * @param threadId  RFC Message-ID of the thread root.
     * @param messageId RFC Message-ID of this message.
     * @return The unsaved EmailMessage.
     */
    private static EmailMessage buildCapture(String threadId, String messageId) {
        return new EmailMessage(
            Subject = 'captured',
            Status = '3',
            Incoming = false,
            ThreadIdentifier = threadId,
            MessageIdentifier = messageId,
            FromAddress = 'junior@example.invalid',
            ToAddress = 'guard.broker@example.invalid'
        );
    }

    /**
     * Inserts one captured email, optionally relates it to a Lead the way EAC does,
     * and re-reads it so the platform-stamped ActivityId is available.
     *
     * ⚠ ActivityId IS SYSTEM-WRITABLE ONLY (gotcha 1) — a test cannot set it, and does
     * not need to: Enhanced Email auto-creates the companion Task on insert and stamps
     * it. The assertion below is C-8: if Enhanced Email is ever disabled in this org
     * the companion disappears, the guard silently loses its fingerprint, and every
     * delete test would otherwise pass VACUOUSLY. Fail loud, here, on the precondition.
     *
     * @param leadId    Lead to associate via EmailMessageRelation; required.
     * @param threadId  RFC Message-ID of the thread root.
     * @param messageId RFC Message-ID of this message.
     * @return The re-read EmailMessage with ActivityId populated.
     */
    private static EmailMessage makeCapturedEmail(Id leadId, String threadId, String messageId) {
        EmailMessage capture = buildCapture(threadId, messageId);
        insert capture;
        insert new EmailMessageRelation(
            EmailMessageId = capture.Id, RelationId = leadId, RelationType = 'ToAddress');
        EmailMessage stored = [
            SELECT Id, ActivityId, ThreadIdentifier, MessageIdentifier
            FROM EmailMessage
            WHERE Id = :capture.Id
        ];
        Assert.isNotNull(stored.ActivityId,
            'PRECONDITION FAILED: Enhanced Email must auto-create the companion Task and stamp '
            + 'EmailMessage.ActivityId on insert. A null ActivityId means Enhanced Email is '
            + 'disabled in this org — the EAC Thread Guard cannot fingerprint anything without '
            + 'it, and every delete test in this class would pass vacuously');
        return stored;
    }
}
