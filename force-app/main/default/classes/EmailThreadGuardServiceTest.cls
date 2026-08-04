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
 * ═══ GUARD 5 — TIMELINE DEDUP (added 2026-08-04, `agent-output/design-requirements-
 * timeline-dedup.md`) ═══
 * The new rule deletes an EAC capture that ADDS NOTHING NEW: it is `Incoming`, its
 * `MessageIdentifier` exactly equals a pipeline `Task.Inbound_Message_Id__c`, and that
 * pipeline row is present on EVERY record the capture lives on (Leads ∪ RelatedToId).
 *
 * 🔴 **THE CRITICAL PRE-EXISTING GAP THIS CLOSES.** Every `EmailMessage` fixture in
 * this file — and in every sibling EAC test class — hardcodes `Incoming = false` via
 * the 2-arg `buildCapture`/`makeCapturedEmail`. Guard 5's FIRST term is
 * `message.Incoming != true`, so **not one pre-existing test in this class could ever
 * reach guard 5** before this pass — they all short-circuit KEEP on direction alone,
 * regardless of what guard 5's Message-ID logic does. New 3/4-arg overloads
 * (`buildCapture(threadId, messageId, incoming)` /
 * `makeCapturedEmail(leadId, threadId, messageId, incoming)`) let a test opt into
 * `Incoming = true`. **The 2-arg defaults are UNCHANGED and must stay that way** —
 * flipping them would turn `anchorMatchViaMessageIdentifierAloneIsKept` red (see its
 * own Javadoc) and silently re-scope every pre-guard-5 test in this class into guard
 * 5's territory.
 *
 * New tests (all use the 3/4-arg `Incoming = true` overloads unless proving the
 * outbound-protection case, which deliberately uses `Incoming = false`):
 *   • `exactMessageIdDuplicateOnTheSameLead_isDeletedAndThePipelineRowSurvives` — happy
 *     path AND the 2→1-never-1→0 invariant in one test.
 *   • `outboundCaptureWithExactMessageIdMatch_isNeverDeleted` — isolates the `Incoming`
 *     term with the strongest possible adversarial input (an EXACT Message-ID match).
 *   • `inboundReplySharingTheThreadRootButNotTheMessageId_isKept` — pins
 *     Message-ID-only, never Thread-Key, end to end through `run()`.
 *   • `duplicateOnOneOfTwoLeadsWithoutPipelineTaskOnTheOther_isKept` /
 *     `duplicateOnBothLeadsWithPipelineTasksEverywhere_isDeleted` — the universal
 *     quantifier across related Leads, both directions.
 *   • `duplicateWithRelatedToIdPointingAtAnUnanchoredRecord_isKept` /
 *     `duplicateWithRelatedToIdAlsoCarryingThePipelineRow_isDeleted` — the same
 *     quantifier on the RelatedToId leg.
 *   • `exactDuplicateAlsoLivingOnAContact_isKeptByGuard2Ordering` — proves admissibility
 *     (guard 2) runs BEFORE guard 5 is ever evaluated.
 *   • `dedupeAt251Captures_isBulkSafe` — 251 exact duplicates, one delete pair.
 *   • `dedupeThroughTheRealQueueablePath_staysWithinTheUnchangedQueryBudget` — guard 5
 *     costs ZERO new SOQL in the shared `EmailCaptureQueueable` execution.
 *   • `pipelineAnchorTaskIsStructurallyUnreachableViaGuard5Duplicates` — extends the
 *     structural-unreachability proof to the new delete reason.
 *
 * Two branches were found to be UNTESTABLE through the public surface, deliberately
 * left unpinned rather than faked — both are recorded here rather than as a TODO in
 * the code, since neither is a gap in the PRODUCTION reasoning, only in what a test
 * can observe:
 *   1. **`relatedLeadIds` empty inside `isExactPipelineDuplicate`.** `run()`'s own
 *      admissibility guard 1 (`relatedLeadIds == null`) already makes this
 *      unreachable — `RelationIndex.leadIdsByMessageId` only ever stores a KEY once at
 *      least one Lead relation exists, and it always seeds that entry with >=1 member
 *      in the same statement. The production Javadoc says as much ("here so a future
 *      reordering of the guards cannot turn silence into a deletion"); there is no DML
 *      shape that produces a non-null, empty set at that call site.
 *   2. **A genuinely NULL `Incoming`.** `EmailMessage.Incoming` is a standard checkbox
 *      field; Salesforce coerces an explicit `null` assignment to `false` on save, and
 *      a queried Boolean field can never return null. `outboundCaptureWithExactMessage-
 *      IdMatch_isNeverDeleted` (`Incoming = false`) already exercises the operative
 *      `!= true` behaviour for every state this org can actually persist.
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
     *
     * ⚠ CONDITIONALLY GREEN SINCE GUARD 5 WAS ADDED (2026-08-04) — READ BEFORE
     * TOUCHING THE FIXTURE. This capture's `MessageIdentifier` (`replyOwnId`) is an
     * EXACT match for the anchor's `Inbound_Message_Id__c` — the same shape guard 5
     * deletes in `exactMessageIdDuplicateOnTheSameLead_isDeletedAndThePipelineRowSurvives`.
     * This test stays green ONLY because `makeCapturedEmail`'s 3-arg form defaults
     * `Incoming = false`, which guard 5's first term (`!= true`) excludes before its
     * Message-ID logic ever runs. If a future change flips that default, THIS test —
     * not a new one — is what goes red, and for a reason unrelated to the OR-term it
     * was written to isolate. Do not re-point it to Thread_Key__c anchoring to "fix"
     * that risk: `inboundReplySharingTheThreadRootButNotTheMessageId_isKept` already
     * owns that shape, and re-pointing this one would delete the only coverage of
     * `isAnchoredOn`'s MessageIdentifier OR-term.
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

        // PIN, HOISTED TO A PRECONDITION (see this method's class-header note): this
        // fixture is only outside guard 5's reach because Incoming is false. Checked HERE,
        // before the run, so a future default-flip on makeCapturedEmail's 3-arg form fails
        // LOUD and SELF-DIAGNOSING right at the fixture, instead of surfacing as a red
        // keep-assertion below whose message talks about the OR-term and gives no hint
        // that guard 5 (not guard 4) is what actually fired.
        Assert.isFalse(capture.Incoming,
            'PIN: this fixture must stay Incoming = false, or guard 5 (exact pipeline '
            + 'duplicate) deletes this capture before the OR-term below is ever reached. If '
            + 'this fails, makeCapturedEmail\'s 3-arg default was flipped to Incoming = true — '
            + 'fix that default (or call the explicit-Incoming overload here), not the '
            + 'assertion below');

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
    // GUARD 5 — TIMELINE DEDUP (added 2026-08-04). See the class header for why every
    // test below uses the 3/4-arg `Incoming = true` overloads and why the pre-existing
    // suite above could never reach this code path.
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * THE HAPPY PATH, combined with the invariant guard 5 *is*: a pipeline row must
     * already exist on every record the capture is removed from, so a timeline goes
     * 2 -> 1, never 1 -> 0. Asserting only that the EAC copy died would not prove the
     * pipeline's own copy of the same email is still represented on the timeline —
     * this test asserts both in one pass.
     */
    @isTest
    static void exactMessageIdDuplicateOnTheSameLead_isDeletedAndThePipelineRowSurvives() {
        Lead broker = makeLead();
        String sharedMessageId = 'pipeline-logged@mail.example.invalid';
        Task pipelineAnchor = anchorTask(broker.Id, sharedMessageId); // root == its own id
        insert pipelineAnchor;

        // EAC's copy of the SAME email the pipeline already logged.
        EmailMessage duplicate = makeCapturedEmail(broker.Id, sharedMessageId, sharedMessageId, true);
        Id companionId = duplicate.ActivityId;

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ duplicate.Id });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM EmailMessage WHERE Id = :duplicate.Id],
            'EAC\'s copy of an email the pipeline already logged (exact Message-ID match) must '
            + 'be removed');
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE Id = :companionId],
            'Its companion Task must go with it');
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE Id = :pipelineAnchor.Id],
            'THE 2->1, NEVER 1->0 INVARIANT: the pipeline\'s own Task for this exact Message-ID '
            + 'must survive on the Lead. Asserting only that the EAC copy died does not prove '
            + 'the email is still represented on the timeline');
    }

    /**
     * 🔴 THE MOST IMPORTANT NEGATIVE TEST GUARD 5 HAS. EAC is the ONLY source of
     * outbound mail anywhere in Salesforce — the pipeline only ever logs inbound. This
     * proves the `Incoming != true` term ALONE protects outbound mail, with the
     * strongest possible adversarial input: the capture's own MessageIdentifier is an
     * EXACT match for a pipeline anchor's Inbound_Message_Id__c (the identical setup
     * that gets an INBOUND capture deleted in the happy-path test above). Direction —
     * not the identifier match — is what discriminates the two.
     */
    @isTest
    static void outboundCaptureWithExactMessageIdMatch_isNeverDeleted() {
        Lead broker = makeLead();
        String sharedMessageId = 'outbound-shares-this-id@mail.example.invalid';
        insert anchorTask(broker.Id, sharedMessageId);

        EmailMessage outboundReply = makeCapturedEmail(
            broker.Id, sharedMessageId, sharedMessageId, false); // Incoming = false

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ outboundReply.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM EmailMessage WHERE Id = :outboundReply.Id],
            'An OUTBOUND capture must never be deleted as a pipeline duplicate, even when its '
            + 'own Message-ID exactly equals a pipeline anchor\'s Inbound_Message_Id__c');
    }

    /**
     * 🔴 MESSAGE-ID ONLY, NEVER THREAD-KEY — pinned end to end through the guard's
     * public entry point (EmailThreadAnchorServiceTest pins the same contract directly
     * on the accessor). A broker's 2nd/3rd reply in an anchored thread shares the
     * thread ROOT with every other message in the conversation, but the pipeline has
     * never logged THIS particular message — so it must be KEPT. If
     * isExactPipelineDuplicate were ever "simplified" to reuse isAnchoredOn's union
     * (Thread_Key__c OR Inbound_Message_Id__c) instead of the Message-ID-only
     * accessor, this goes red — and this is the single easiest mistake to make in
     * this file (see EmailThreadAnchorService.isMessageIdAnchoredOn's own header).
     */
    @isTest
    static void inboundReplySharingTheThreadRootButNotTheMessageId_isKept() {
        Lead broker = makeLead();
        // Reply-anchor shape: Thread_Key__c is the ROOT, Inbound_Message_Id__c is the
        // PIPELINE's OWN first message — different from the capture's own id below.
        insert new Task(WhoId = broker.Id, Subject = 'Email: deal', Status = 'Completed',
                        TaskSubtype = 'Email', Thread_Key__c = DEAL_ROOT,
                        Inbound_Message_Id__c = 'pipeline-first-message@mail.example.invalid');

        // EAC's capture of a LATER reply in the SAME thread the pipeline never logged.
        EmailMessage laterReply = makeCapturedEmail(
            broker.Id, DEAL_ROOT, 'eac-only-reply@mail.example.invalid', true);

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ laterReply.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM EmailMessage WHERE Id = :laterReply.Id],
            'A reply sharing the anchored thread ROOT, but carrying a Message-ID the pipeline '
            + 'never logged, must be KEPT — a Thread-Key match is "something in this '
            + 'conversation was logged", not "this exact message was logged"');
    }

    /**
     * 🔴 GUARD 5 IS UNIVERSAL (&& across every record the capture lives on) — the
     * exact opposite quantifier from guard 4's existential (||). A capture stapled to
     * TWO Leads is deletable only when EVERY one of them already carries the pipeline
     * row; one Lead without it keeps the whole capture, even on the Lead that DOES
     * carry it.
     */
    @isTest
    static void duplicateOnOneOfTwoLeadsWithoutPipelineTaskOnTheOther_isKept() {
        Lead leadWithPipelineRow = makeLead();
        Lead leadWithoutPipelineRow = makeLead();
        String sharedMessageId = 'multi-lead-shared@mail.example.invalid';
        insert anchorTask(leadWithPipelineRow.Id, sharedMessageId);
        // leadWithoutPipelineRow carries NO Task at all.

        EmailMessage capture = makeCapturedEmail(
            leadWithPipelineRow.Id, sharedMessageId, sharedMessageId, true);
        relate(capture.Id, leadWithoutPipelineRow.Id, 'ToAddress');

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ capture.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM EmailMessage WHERE Id = :capture.Id],
            'A capture living on TWO Leads is not deletable when only ONE of them carries the '
            + 'pipeline row — the per-record redundancy test must hold on EVERY record it lives '
            + 'on');
    }

    /**
     * The positive counterweight: once BOTH Leads carry a pipeline Task for this exact
     * Message-ID (the shape multi-property routing produces — N Tasks sharing one
     * Message-ID across N records), the capture is redundant everywhere it lives and
     * is deleted, while BOTH pipeline anchors survive.
     */
    @isTest
    static void duplicateOnBothLeadsWithPipelineTasksEverywhere_isDeleted() {
        Lead leadA = makeLead();
        Lead leadB = makeLead();
        String sharedMessageId = 'multi-lead-both-anchored@mail.example.invalid';
        Task anchorA = anchorTask(leadA.Id, sharedMessageId);
        Task anchorB = anchorTask(leadB.Id, sharedMessageId);
        insert new List<Task>{ anchorA, anchorB };

        EmailMessage capture = makeCapturedEmail(leadA.Id, sharedMessageId, sharedMessageId, true);
        relate(capture.Id, leadB.Id, 'ToAddress');
        // AFTER the second relation — it replaced the companion Task (see `relate`, fact 2).
        Id companionId = companionIdOf(capture.Id);

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ capture.Id });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM EmailMessage WHERE Id = :capture.Id],
            'A capture redundant on EVERY Lead it lives on must be deleted');
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE Id = :companionId],
            'Its companion Task must go with it');
        Set<Id> anchorIds = new Set<Id>{ anchorA.Id, anchorB.Id };
        Assert.areEqual(2, [SELECT COUNT() FROM Task WHERE Id IN :anchorIds],
            'BOTH pipeline anchors must survive — guard 5 never touches a pipeline Task');
    }

    /**
     * 🔴 THE RelatedToId LEG OF GUARD 5 — the same universal-quantifier reasoning as
     * the two-Lead tests above, on the OTHER record guard 5 consults. A capture that
     * is an exact duplicate on its Lead but ALSO lives on a RelatedToId record with NO
     * pipeline row must be KEPT.
     */
    @isTest
    static void duplicateWithRelatedToIdPointingAtAnUnanchoredRecord_isKept() {
        Lead broker = makeLead();
        String sharedMessageId = 'relatedto-leg-unanchored@mail.example.invalid';
        insert anchorTask(broker.Id, sharedMessageId);
        Opportunity unanchoredOpportunity = TestDataFactory.createOpportunity(null, true);

        EmailMessage capture = makeCapturedEmailWithRelatedTo(
            broker.Id, sharedMessageId, sharedMessageId, true, unanchoredOpportunity.Id);

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ capture.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM EmailMessage WHERE Id = :capture.Id],
            'The capture is redundant on its Lead but ALSO lives on its RelatedToId '
            + 'Opportunity, which carries no pipeline row for this Message-ID — guard 5 must '
            + 'fail on that leg and keep the capture, exactly as it would for a second '
            + 'unanchored Lead');
    }

    /**
     * The positive counterweight on the RelatedToId leg: once the RelatedToId record
     * ALSO carries the pipeline row for this exact Message-ID — the state a completed
     * adoption leaves behind (see EmailThreadAdopterServiceTest's guard-4 analogue,
     * `adoptedCaptureIsKeptByTheGuard_viaTheRelatedToIdLeg`) — the capture is redundant
     * everywhere it lives and is deleted.
     */
    @isTest
    static void duplicateWithRelatedToIdAlsoCarryingThePipelineRow_isDeleted() {
        Lead broker = makeLead();
        Opportunity anchoredOpportunity = TestDataFactory.createOpportunity(null, true);
        String sharedMessageId = 'relatedto-leg-anchored@mail.example.invalid';
        Task leadAnchor = anchorTask(broker.Id, sharedMessageId);
        Task opportunityAnchor = new Task(
            WhatId = anchoredOpportunity.Id, Subject = 'Email: deal', Status = 'Completed',
            TaskSubtype = 'Email', Thread_Key__c = sharedMessageId,
            Inbound_Message_Id__c = sharedMessageId);
        insert new List<Task>{ leadAnchor, opportunityAnchor };

        EmailMessage capture = makeCapturedEmailWithRelatedTo(
            broker.Id, sharedMessageId, sharedMessageId, true, anchoredOpportunity.Id);
        Id companionId = capture.ActivityId; // no further relation added after this — still fresh

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ capture.Id });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM EmailMessage WHERE Id = :capture.Id],
            'A capture redundant on its Lead AND on its RelatedToId Opportunity must be deleted');
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE Id = :companionId],
            'Its companion Task must go with it');
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE Id = :leadAnchor.Id],
            'The Lead-side pipeline anchor must survive');
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE Id = :opportunityAnchor.Id],
            'The Opportunity-side pipeline anchor must survive too');
    }

    /**
     * 🔴 GUARD ORDERING — scope guard 2 (admissibility) runs BEFORE guard 5 is ever
     * evaluated. A capture that WOULD be an exact pipeline duplicate on its Lead,
     * judged in isolation, must still be KEPT when it also lives on a Contact — guard
     * 2 excludes it before guard 4/5 are reached at all. This is the documented
     * converted-deal boundary (class header, "KNOWN SCOPE BOUNDARY") pinned as
     * behaviour rather than left implicit.
     */
    @isTest
    static void exactDuplicateAlsoLivingOnAContact_isKeptByGuard2Ordering() {
        Lead broker = makeLead();
        Contact brokerContact = TestDataFactory.createBrokerContact(null, true);
        String sharedMessageId = 'guard-ordering-duplicate@mail.example.invalid';
        insert anchorTask(broker.Id, sharedMessageId);

        EmailMessage capture = makeCapturedEmail(broker.Id, sharedMessageId, sharedMessageId, true);
        relate(capture.Id, brokerContact.Id, 'ToAddress');
        // AFTER the Contact relation — it replaced the companion Task (see `relate`, fact 2).
        Id companionId = companionIdOf(capture.Id);

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ capture.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM EmailMessage WHERE Id = :capture.Id],
            'A capture that would be an exact pipeline duplicate judged on the Lead alone must '
            + 'still be KEPT once it also lives on a Contact — scope guard 2 excludes it before '
            + 'guard 5 is ever reached. Remove guard 2 and this goes red for the SAME reason '
            + 'captureAlsoLivingOnAContactIsKept does');
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE Id = :companionId],
            'Its companion Task must survive too, or the Contact timeline loses the entry '
            + 'anyway');
    }

    /**
     * BULK SAFETY for guard 5 at the volume EAC actually produces — mirrors
     * guardAt251Captures_isBulkSafe exactly, except every capture is an EXACT
     * pipeline duplicate instead of unanchored, so this exercises guard 5's
     * per-record loop and its shared delete pair at volume in one DML.
     */
    @isTest
    static void dedupeAt251Captures_isBulkSafe() {
        final Integer volume = 251;
        Lead broker = makeLead();

        List<Task> pipelineAnchors = new List<Task>();
        for (Integer i = 0; i < volume; i++) {
            pipelineAnchors.add(anchorTask(broker.Id, 'dedupe-bulk-' + i + '@mail.example.invalid'));
        }
        insert pipelineAnchors;

        List<EmailMessage> captures = new List<EmailMessage>();
        for (Integer i = 0; i < volume; i++) {
            String messageId = 'dedupe-bulk-' + i + '@mail.example.invalid';
            captures.add(buildCapture(messageId, messageId, true)); // exact duplicate, inbound
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
            + ' captures, or the bulk dedupe path is not actually being exercised');

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(captureIds);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM EmailMessage WHERE Id IN :captureIds],
            'All ' + volume + ' exact duplicates must be removed in one pass');
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE Id IN :companionIds],
            'All ' + volume + ' companion Tasks must be removed alongside their messages');
        Set<Id> pipelineAnchorIds = new Map<Id, Task>(pipelineAnchors).keySet();
        Assert.areEqual(volume, [SELECT COUNT() FROM Task WHERE Id IN :pipelineAnchorIds],
            'All ' + volume + ' pipeline anchor Tasks must survive — guard 5 never touches a '
            + 'pipeline Task, at any volume');
    }

    /**
     * GOVERNOR REGRESSION — guard 5 must cost ZERO new SOQL. Drives one exact
     * duplicate through the REAL trigger -> EmailCaptureQueueable path (not a direct
     * service call) and reads the query budget the way
     * EmailThreadAdopterServiceTest.adopterAt251Captures_isBulkSafe does:
     * EmailCaptureQueueable.lastRunQueryCount, read AFTER Test.stopTest() — safe here
     * because it is a static the async execution itself set, not Limits.* (which
     * stopTest() resets and would make the read vacuous).
     */
    @isTest
    static void dedupeThroughTheRealQueueablePath_staysWithinTheUnchangedQueryBudget() {
        final Integer queueableQueryBudget = 7; // unchanged by design — see
                                                 // EmailThreadAdopterServiceTest.QUEUEABLE_QUERY_BUDGET
        Lead broker = makeLead();
        String duplicateId = 'governor-budget-dup@mail.example.invalid';
        insert new Task(WhoId = broker.Id, Subject = 'Email: deal', Status = 'Completed',
                        TaskSubtype = 'Email', Thread_Key__c = DEAL_ROOT,
                        Inbound_Message_Id__c = duplicateId);

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailMessage duplicate = makeCapturedEmail(broker.Id, DEAL_ROOT, duplicateId, true);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM EmailMessage WHERE Id = :duplicate.Id],
            'Precondition: the duplicate must actually have been deleted by the real pipeline '
            + 'pass, or the query-budget reading below is not measuring guard 5 at all');
        Assert.areEqual(queueableQueryBudget, EmailCaptureQueueable.lastRunQueryCount,
            'GOVERNOR HEADROOM, BOTH DIRECTIONS: the shared queueable execution must spend '
            + 'EXACTLY ' + queueableQueryBudget + ' queries (anchor index 2, adopter 2, guard '
            + '3) — never merely at-or-under that budget. An INCREASE regresses governor '
            + 'headroom, but a DECREASE is the dangerous direction for this destructive '
            + 'pipeline: if a query silently disappears (e.g. the anchor read), every capture '
            + 'looks unanchored to the guard and it MASS-DELETES. A <= assertion cannot catch '
            + 'that direction at all. Observed ' + EmailCaptureQueueable.lastRunQueryCount + '.');
    }

    /**
     * Extends the structural-unreachability proof to the delete reason ADDED by guard
     * 5. Same shape as pipelineAnchorTaskIsStructurallyUnreachable, but the capture
     * deleted here is an EXACT DUPLICATE rather than merely unanchored — proving the
     * new delete reason still reaches a Task ONLY through EmailMessage.ActivityId,
     * never through the anchor Task it matched against.
     */
    @isTest
    static void pipelineAnchorTaskIsStructurallyUnreachableViaGuard5Duplicates() {
        Lead broker = makeLead();
        String sharedMessageId = 'structural-guard5@mail.example.invalid';
        Task pipelineAnchor = anchorTask(broker.Id, sharedMessageId);
        insert pipelineAnchor;
        EmailMessage duplicate = makeCapturedEmail(broker.Id, sharedMessageId, sharedMessageId, true);
        Id companionId = duplicate.ActivityId;
        Assert.areNotEqual(pipelineAnchor.Id, companionId,
            'Precondition: the pipeline anchor and the EAC companion must be different Tasks, '
            + 'or this test proves nothing');

        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadGuardService.run(new Set<Id>{ duplicate.Id });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM EmailMessage WHERE Id = :duplicate.Id],
            'The exact duplicate is deleted, so guard 5 did run a real deletion pass');
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE Id = :companionId],
            'Its companion Task — reachable via ActivityId — is deleted');
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE Id = :pipelineAnchor.Id],
            'The pipeline anchor Task — the very Task guard 5 matched AGAINST — survives: the '
            + 'anchor index is a read-only decision input whose rows never enter a delete list, '
            + 'even for the delete reason that reads it to decide redundancy');
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
     * An unsaved EmailMessage in the shape EAC materializes. Defaults to
     * `Incoming = false` — see this class's header ("THE CRITICAL PRE-EXISTING GAP")
     * for why that default must never change.
     *
     * @param threadId  RFC Message-ID of the thread root.
     * @param messageId RFC Message-ID of this message.
     * @return The unsaved EmailMessage.
     */
    private static EmailMessage buildCapture(String threadId, String messageId) {
        return buildCapture(threadId, messageId, false);
    }

    /**
     * OVERLOAD (guard 5 dedup tests, 2026-08-04): lets a test choose the capture's
     * direction. Guard 5's first term is `message.Incoming != true`, so this is the
     * only way to reach it at all — every fixture in this file predates guard 5 and
     * is outbound-shaped by default.
     *
     * @param threadId  RFC Message-ID of the thread root.
     * @param messageId RFC Message-ID of this message.
     * @param incoming  The message direction guard 5's first term reads.
     * @return The unsaved EmailMessage.
     */
    private static EmailMessage buildCapture(String threadId, String messageId, Boolean incoming) {
        return new EmailMessage(
            Subject = 'captured',
            Status = '3',
            Incoming = incoming,
            ThreadIdentifier = threadId,
            MessageIdentifier = messageId,
            FromAddress = 'junior@example.invalid',
            ToAddress = 'guard.broker@example.invalid'
        );
    }

    /**
     * Inserts one captured email, relates it to a Lead the way EAC does, and re-reads
     * it so the platform-stamped ActivityId is available. Defaults to
     * `Incoming = false` for backward compatibility with every pre-guard-5 test in
     * this file — see the 4-arg overload for the guard 5 dedup tests.
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
        return makeCapturedEmail(leadId, threadId, messageId, false);
    }

    /**
     * OVERLOAD (guard 5 dedup tests, 2026-08-04): lets a test choose the capture's
     * direction, and widens the re-query to include `Incoming` and `RelatedToId` so a
     * caller can assert on them directly (see
     * `anchorMatchViaMessageIdentifierAloneIsKept`'s pinning assertion).
     *
     * @param leadId    Lead to associate via EmailMessageRelation; required.
     * @param threadId  RFC Message-ID of the thread root.
     * @param messageId RFC Message-ID of this message.
     * @param incoming  The message direction guard 5's first term reads.
     * @return The re-read EmailMessage with ActivityId populated.
     */
    private static EmailMessage makeCapturedEmail(
            Id leadId, String threadId, String messageId, Boolean incoming) {
        EmailMessage capture = buildCapture(threadId, messageId, incoming);
        insert capture;
        insert new EmailMessageRelation(
            EmailMessageId = capture.Id, RelationId = leadId, RelationType = 'ToAddress');
        EmailMessage stored = [
            SELECT Id, ActivityId, ThreadIdentifier, MessageIdentifier, Incoming, RelatedToId
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

    /**
     * Builds and inserts a capture the way `makeCapturedEmail` does, but ALSO seeds
     * `RelatedToId` AT INSERT — the only point that field reliably accepts a value in
     * this org (measured; see `EmailThreadAdopterServiceTest`'s class header: an
     * insert-time seed persists, while a post-insert UPDATE is refused under
     * `@isTest` — an independent, documented platform quirk unrelated to this test).
     * Used only by the guard-5 RelatedToId-leg tests, which need EAC to have already
     * related the capture to a record the guard must independently examine.
     *
     * @param leadId      Lead to associate via EmailMessageRelation; required.
     * @param threadId    RFC Message-ID of the thread root.
     * @param messageId   RFC Message-ID of this message.
     * @param incoming    The message direction guard 5's first term reads.
     * @param relatedToId Seeded at insert.
     * @return The re-read EmailMessage with ActivityId and RelatedToId populated.
     */
    private static EmailMessage makeCapturedEmailWithRelatedTo(
            Id leadId, String threadId, String messageId, Boolean incoming, Id relatedToId) {
        EmailMessage capture = buildCapture(threadId, messageId, incoming);
        capture.RelatedToId = relatedToId;
        insert capture;
        insert new EmailMessageRelation(
            EmailMessageId = capture.Id, RelationId = leadId, RelationType = 'ToAddress');
        EmailMessage stored = [
            SELECT Id, ActivityId, ThreadIdentifier, MessageIdentifier, Incoming, RelatedToId
            FROM EmailMessage
            WHERE Id = :capture.Id
        ];
        Assert.isNotNull(stored.ActivityId,
            'PRECONDITION FAILED: Enhanced Email must auto-create the companion Task and stamp '
            + 'EmailMessage.ActivityId on insert (see makeCapturedEmail)');
        Assert.areEqual(relatedToId, stored.RelatedToId,
            'PRECONDITION FAILED: RelatedToId must persist as seeded at insert, or the '
            + 'RelatedToId-leg tests are not testing what they claim to');
        return stored;
    }
}
