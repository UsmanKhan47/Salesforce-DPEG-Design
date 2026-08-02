/**
 * Tests for EmailThreadAdopterService — the EAC Thread Adopter decision layer, plus the
 * cross-feature contract with the guard that runs immediately after it.
 *
 * ═══ 🔴 READ THIS FIRST: WHY THESE TESTS ASSERT DECISIONS, NOT COMMITTED STATE ═══
 * `EmailMessage.RelatedToId` cannot be written from `@isTest` against a test-created
 * capture. `describe.updateable` says TRUE **and is wrong** — that flag is exactly what
 * let this feature reach a deploy before the problem surfaced, so do not re-describe the
 * field and call it verified.
 *
 * What is established is a CORRELATION, not a mechanism:
 *   • the write COMMITS AT RUNTIME — twice on `usman-dpeg` 2026-08-02 against real EAC
 *     capture `02siw0000005prVAAQ` (spike experiment 3a: set, then revert, each
 *     readback-confirmed);
 *   • the write IS REFUSED here — 7 probes plus the 2026-08-02 deploy fingerprint, always
 *     `INSUFFICIENT_ACCESS_OR_READONLY … fields=(RelatedToId)`, independent of message
 *     Status (Sent and Draft both), independent of any relation, and not a whole-record
 *     lock (`Subject` updates fine on the same row);
 *   • the two runs differ in MORE THAN ONE VARIABLE at once (test context vs runtime AND
 *     test-created row vs real EAC row). **Which one is the mechanism is undetermined —
 *     do not quote this header as saying either.**
 *   • INSERT-time seeding DOES persist, which is how the tests below stage
 *     already-adopted state.
 *
 * So every test asserts the DECISION — which rows the D4 chain selected and which
 * Opportunity it chose — through the `AdoptionWriter` seam, which receives exactly what
 * `commitAdoptions` passes post-decision. The decision logic itself is never injected.
 *
 * ⚠ **THE NEGATIVE PATHS WERE LATENTLY VACUOUS BEFORE THIS CHANGE** (found at review of
 * the failed deploy). "Assert the field is unchanged" passes whether or not the guards
 * work, because no write ever lands in this context. They now assert the recorder
 * received ZERO ROWS, which fails the moment a guard stops blocking.
 *
 * ═══ WHY THE 251-RECORD MANDATE APPLIES HERE (and the singleton exemption does NOT) ═══
 * `.claude/rules/bulk-test-rule.md` exempts per-transaction-singleton async pipelines.
 * THIS CLASS IS NOT ONE: the adopter is TRIGGER-DRIVEN and Einstein Activity Capture
 * BATCH-INSERTS its captures, so hundreds of message Ids in one transaction is normal.
 * `adopterAt251Captures_isBulkSafe` is a literal 251 through the REAL trigger path and
 * deliberately keeps the REAL writer: `Database.update` on a list is ONE DML statement
 * even when every row is refused, so the exactly-1-DML and constant-query-budget
 * assertions stay meaningful, and the refusal codes prove those rows were selected.
 *
 * ═══ WHY EVERY ADOPT TEST SETS `treatAllAsMaterialized` ═══
 * The EAC fingerprint (`companion Task.CreatedBy.UserType == 'AutomatedProcess'`) cannot
 * be reproduced in a test. `captureThatIsNotEacFingerprintedIsNeverTouched` deliberately
 * leaves the seam OFF; that is the one test where the fingerprint is the subject.
 *
 * ═══ 🔴 WHY COUNTER **AND RECORDER** ASSERTIONS READ THEIR VALUE INSIDE THE BLOCK ═══
 *   1. `Test.stopTest()` RESTORES pre-test limit counters, so any assertion built on
 *      `Limits.*` after it is vacuous — hence the `lastRun*` statics.
 *   2. Inserting an EmailMessage fires the REAL trigger, which enqueues a real
 *      EmailCaptureQueueable that runs AT `stopTest()` — after the explicit call under
 *      test — and overwrites those statics with its own pass.
 *   3. ⚠ **THE RECORDER HAS THE SAME EXPOSURE, and it bit once** (deploy attempt 2:
 *      `firstPassRecordsExactlyOneWrite` saw 2). The double is a static, so it stays
 *      installed for that trigger-driven pass; and because the double never COMMITS,
 *      `RelatedToId` is still null when that pass runs, so the D4 chain legitimately
 *      selects the same capture AGAIN and the recorder ACCUMULATES. Any count- or
 *      contents-based assertion is therefore snapshotted into a local immediately after
 *      the explicit `run(...)`.
 *
 * Two consequences worth knowing before editing a test here:
 *   • A `Set<Id>` assertion SILENTLY TOLERATES that duplicate (same Id collapses), so it
 *     looks green while pinning less than it appears to. Every positive path now pairs its
 *     Id-set assertion with an explicit `writeCount` so the tolerance is closed.
 *   • For NEGATIVE paths the post-`stopTest()` total is STRICTLY STRONGER than the
 *     snapshot (it covers the trigger pass too), so those tests assert BOTH.
 *
 * Leaving the double installed for the trigger pass is deliberate: it keeps that pass off
 * the real writer, so it neither burns a DML nor logs a spurious refusal.
 *
 * ═══ 🔴 WHICH COUNTERS MEAN ANYTHING UNDER WHICH WRITER — CHECK BEFORE ASSERTING ═══
 * The double replaces the DML call, so it changes what each counter can possibly say. A
 * third deploy was spent on an assertion that contradicted this (`dmlStatements == 1` in a
 * doubled test, which can NEVER pass), and it only surfaced after an earlier assertion in
 * the same method was fixed — the contradiction had been hiding behind a line that failed
 * first. Assume others are hiding the same way and check this table when adding one:
 *
 *   | counter                | with RecordingWriter          | with the real writer        |
 *   |------------------------|-------------------------------|-----------------------------|
 *   | `lastRunDmlStatements` | ALWAYS 0 — asserting anything |  meaningful: 1 statement per |
 *   |                        | else is a contradiction; 0 is |  pass that selected rows,    |
 *   |                        | vacuous (cannot fail)         |  0 when it selected none     |
 *   | `lastRunQueryCount`    | MEANINGFUL — the double does  |  meaningful, identical       |
 *   |                        | not touch SOQL                |                             |
 *   | `lastRunAdoptedCount`  | = rows the DECISION selected  |  = rows the PLATFORM accepted|
 *   |                        | (fabricated successes)        |  (currently always 0)        |
 *   | `lastRunFailureCodes`  | ALWAYS empty                  |  the refusals — the canary   |
 *   | `recorder.recorded`    | THE decision evidence         |  n/a (no recorder installed) |
 *
 * Rule of thumb: **in a doubled test assert the RECORDER and the QUERY count; never the DML
 * count.** The "one write = one bulk DML statement" property is real and is pinned where
 * the real writer runs — `adopterAt251Captures_isBulkSafe` and the quirk canary.
 *
 * ═══ MEASURED PLATFORM FACTS THE HELPERS ENCODE (do not re-derive them) ═══
 *   1. `ActivityId` is system-writable only, and is stamped only once the message RELATES
 *      to a record — so `insertCapture` relates BEFORE re-reading it.
 *   2. Adding a relation DELETES and RECREATES the companion Task; any ActivityId read
 *      before the last relation is stale.
 *   3. `EmailMessageRelation` REJECTS Opportunity RelationIds — which is why this feature
 *      adopts through `RelatedToId` and not through a relation row (D1).
 *
 * ASSERTION STYLE: Assert.* — matches the sibling Broker-Protection test classes.
 *
 * @see EmailThreadAdopterService.cls (D4 policy table, D5 invariants, the quirk, R1)
 * @see EmailThreadAnchorServiceTest.cls (normalization + the resolution chain)
 * @see EmailThreadGuardServiceTest.cls (the other half — 12 tests, unmodified)
 */
@isTest
private class EmailThreadAdopterServiceTest {

    private static final String DEAL_ROOT = 'root@deal.example.invalid';
    private static final String NEW_CONVO = 'new-convo@mail.example.invalid';
    private static final String REPLY_ID = 'reply-1@mail.example.invalid';
    private static final String REFUSAL_CODE = 'INSUFFICIENT_ACCESS_OR_READONLY';

    /**
     * The CONSTANT query budget for one full EmailCaptureQueueable execution, whatever
     * the message volume: anchor index (message + anchor reads), adopter (message +
     * companion reads), guard (message + relation + companion reads).
     */
    private static final Integer QUEUEABLE_QUERY_BUDGET = 7;

    // ─────────────────────────────────────────────────────────────────────────
    // The seam double — records the post-decision write so a test can assert WHICH
    // rows the D4 chain chose and WHERE it pointed them.
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Captures exactly what `commitAdoptions` hands the writer and reports success, so the
     * decision is observable without the platform accepting the DML.
     *
     * `Database.SaveResult` has no constructor; JSON deserialization is the standard way
     * to build one in a test.
     */
    private class RecordingWriter implements EmailThreadAdopterService.AdoptionWriter {
        private List<EmailMessage> recorded = new List<EmailMessage>();

        public List<Database.SaveResult> write(List<EmailMessage> adoptions) {
            recorded.addAll(adoptions);
            List<Database.SaveResult> results = new List<Database.SaveResult>();
            for (EmailMessage row : adoptions) {
                results.add((Database.SaveResult) JSON.deserialize(
                    '{"success":true,"id":"' + row.Id + '"}', Database.SaveResult.class));
            }
            return results;
        }

        /** @return The capture Ids the decision selected. */
        private Set<Id> recordedIds() {
            Set<Id> ids = new Set<Id>();
            for (EmailMessage row : recorded) {
                ids.add(row.Id);
            }
            return ids;
        }

        /**
         * @param messageId A capture Id.
         * @return The Opportunity the decision chose for it, or null when unselected.
         */
        private Id targetFor(Id messageId) {
            for (EmailMessage row : recorded) {
                if (row.Id == messageId) {
                    return row.RelatedToId;
                }
            }
            return null;
        }
    }

    /**
     * Installs the recording double.
     *
     * @return The recorder, for assertions.
     */
    private static RecordingWriter useRecordingWriter() {
        RecordingWriter recorder = new RecordingWriter();
        EmailThreadAdopterService.writer = recorder;
        return recorder;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // D4 POLICY MATRIX — positives assert the RECORDED decision; negatives assert the
    // recorder got NOTHING (the vacuity fix).
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * D4 ROW 1 — `RelatedToId` is null and the thread resolves: WRITE it.
     *
     * Also exercises the BRACKET ASYMMETRY end to end: the anchor is stored UNBRACKETED
     * (as `computeThreadKey` writes it) while the capture carries EAC's BRACKETED
     * `ThreadIdentifier`. They match only through the shared normalizer.
     */
    @isTest
    static void adoptsWhenRelatedToIdIsNull() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        insert anchorOnWhat(deal.Id, DEAL_ROOT);
        Lead broker = TestDataFactory.createLead(true);
        EmailMessage capture =
            insertCapture(broker.Id, bracketed(DEAL_ROOT), bracketed(REPLY_ID), null);

        RecordingWriter recorder = useRecordingWriter();
        EmailThreadAdopterService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadAdopterService.run(new Set<Id>{ capture.Id });
        Set<Id> writtenIds = recorder.recordedIds();       // snapshot — see class header
        Integer writeCount = recorder.recorded.size();
        Id writtenTarget = recorder.targetFor(capture.Id);
        Integer adoptedCount = EmailThreadAdopterService.lastRunAdoptedCount;
        Test.stopTest();

        Assert.areEqual(new Set<Id>{ capture.Id }, writtenIds,
            'The capture whose thread the pipeline anchored on a deal must be SELECTED for '
            + 'adoption when RelatedToId is empty — an unbracketed stored anchor must match a '
            + 'bracketed ThreadIdentifier through the shared normalizer');
        Assert.areEqual(1, writeCount,
            'and exactly once: a Set-of-Ids assertion alone would silently tolerate a duplicate '
            + 'write of the same capture');
        Assert.areEqual(deal.Id, writtenTarget,
            'and it must be pointed at the Opportunity the anchor names');
        Assert.areEqual(1, adoptedCount, 'Exactly one capture must be reported adopted');
    }

    /**
     * 🔴 D4 ROW 2 — the crux. EAC arrives having already written an Opportunity into
     * `RelatedToId` that it inferred THREAD-BLINDLY through a matched Contact (measured
     * on both live captures, finding F2). The adopter holds strictly better evidence — an
     * RFC-header identity match against an anchor the pipeline itself wrote — so address
     * inference must LOSE to header identity.
     *
     * The seeded value is set AT INSERT (measured to persist), which is what makes this a
     * real overwrite decision rather than a write onto an empty field.
     */
    @isTest
    static void overwritesAnOpportunityEacInferredFromAnAddress() {
        List<Opportunity> deals = TestDataFactory.createOpportunities(2, true);
        Opportunity anchoredDeal = deals[0];
        Opportunity eacGuess = deals[1];
        insert anchorOnWhat(anchoredDeal.Id, DEAL_ROOT);
        Lead broker = TestDataFactory.createLead(true);
        EmailMessage capture = insertCapture(broker.Id, DEAL_ROOT, REPLY_ID, eacGuess.Id);

        RecordingWriter recorder = useRecordingWriter();
        EmailThreadAdopterService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadAdopterService.run(new Set<Id>{ capture.Id });
        Set<Id> writtenIds = recorder.recordedIds();       // snapshot — see class header
        Integer writeCount = recorder.recorded.size();
        Id writtenTarget = recorder.targetFor(capture.Id);
        Test.stopTest();

        Assert.areNotEqual(anchoredDeal.Id, eacGuess.Id,
            'Precondition: the anchored deal and EAC guess must differ, or nothing is proven');
        Assert.areEqual(eacGuess.Id,
            [SELECT RelatedToId FROM EmailMessage WHERE Id = :capture.Id].RelatedToId,
            'Precondition: the EAC guess must actually be seeded on the row, or the overwrite '
            + 'decision is being made against an empty field');
        Assert.areEqual(new Set<Id>{ capture.Id }, writtenIds,
            'A capture already pointing at a thread-blind Opportunity must still be SELECTED');
        Assert.areEqual(1, writeCount, 'exactly once');
        Assert.areEqual(anchoredDeal.Id, writtenTarget,
            'and must be re-pointed at the Opportunity the thread anchor names. Header identity '
            + 'beats address inference — the same rule the inbound pipeline applies');
    }

    /**
     * D4 ROW 4 — a NON-Opportunity `RelatedToId` is never touched. Same allow-list
     * direction as the guard's W1 fix: an unanticipated object type falls through to
     * "don't touch". `RelatedToId` accepts ~80 types here; this feature claims one.
     *
     * ⚠ VACUITY FIX: asserts the recorder got NOTHING. The old "field unchanged" assertion
     * passed even with the check removed, because no write lands in this context anyway.
     */
    @isTest
    static void leavesANonOpportunityRelatedToIdAlone() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        insert anchorOnWhat(deal.Id, DEAL_ROOT);
        Account somebodyElsesRecord = TestDataFactory.createAccount(true);
        Lead broker = TestDataFactory.createLead(true);
        EmailMessage capture =
            insertCapture(broker.Id, DEAL_ROOT, REPLY_ID, somebodyElsesRecord.Id);

        RecordingWriter recorder = useRecordingWriter();
        EmailThreadAdopterService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadAdopterService.run(new Set<Id>{ capture.Id });
        Integer writeCount = recorder.recorded.size();     // snapshot — see class header
        Test.stopTest();

        Assert.areEqual(somebodyElsesRecord.Id,
            [SELECT RelatedToId FROM EmailMessage WHERE Id = :capture.Id].RelatedToId,
            'Precondition: the Account must be seeded on the row');
        Assert.areEqual(0, writeCount,
            'A capture already related to a NON-Opportunity must never reach the writer — this '
            + 'feature has no mandate over an Account / Case / custom-object timeline. Remove '
            + 'the allow-list check and this goes red');
        Assert.isTrue(recorder.recorded.isEmpty(),
            'and the trigger-driven pass at stopTest must not write it either — for a "never '
            + 'written" claim the post-stopTest total is the stronger check');
        // No DML assertion: under the double it is 0 by construction and could not fail, so it
        // would be a false pin (see class header, "which counters mean anything under which
        // writer"). `writeCount` is the assertion that actually catches a broken guard.
    }

    /**
     * D4 ROW 5 — NULL IS NEVER WRITTEN. The thread anchors only a CONTACT, so the chain
     * fails closed (a Contact fronts many deals). The Contact anchor matters: it makes the
     * index NON-empty, so this proves the fail-closed decision rather than an early exit.
     *
     * ⚠ VACUITY FIX: asserts the recorder got NOTHING.
     */
    @isTest
    static void unresolvedThreadIsNeverSentToTheWriter() {
        Contact brokerContact = TestDataFactory.createBrokerContact(null, true);
        insert anchorOnWho(brokerContact.Id, DEAL_ROOT);
        Opportunity eacGuess = TestDataFactory.createOpportunity(null, true);
        Lead broker = TestDataFactory.createLead(true);
        EmailMessage capture = insertCapture(broker.Id, DEAL_ROOT, REPLY_ID, eacGuess.Id);

        RecordingWriter recorder = useRecordingWriter();
        EmailThreadAdopterService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadAdopterService.run(new Set<Id>{ capture.Id });
        Integer writeCount = recorder.recorded.size();     // snapshot — see class header
        Test.stopTest();

        Assert.areEqual(0, writeCount,
            'When the chain resolves no Opportunity NOTHING may reach the writer. There is no '
            + 'branch that writes null — clearing EAC decision would remove the email from a '
            + 'timeline while giving nothing back');
        Assert.isTrue(recorder.recorded.isEmpty(),
            'and the trigger-driven pass at stopTest must not write it either');
        // No DML assertion — 0 by construction under the double; see class header.
    }

    /**
     * 🔴 THE FINGERPRINT GATE. A composer / Agentforce send's `RelatedToId` was chosen by
     * a HUMAN. With the seam OFF the companion is created by the running user, so the
     * adopter must refuse even though the thread resolves perfectly.
     *
     * ⚠ VACUITY FIX: asserts the recorder got NOTHING. The ActivityId precondition stops
     * this passing merely because the capture had no companion at all.
     */
    @isTest
    static void captureThatIsNotEacFingerprintedIsNeverTouched() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        insert anchorOnWhat(deal.Id, DEAL_ROOT);
        Lead broker = TestDataFactory.createLead(true);
        EmailMessage capture = insertCapture(broker.Id, DEAL_ROOT, REPLY_ID, null);

        RecordingWriter recorder = useRecordingWriter();
        EmailThreadAdopterService.treatAllAsMaterialized = false;
        Test.startTest();
        EmailThreadAdopterService.run(new Set<Id>{ capture.Id });
        Integer writeCount = recorder.recorded.size();     // snapshot — see class header
        Test.stopTest();

        Assert.isNotNull(capture.ActivityId,
            'PRECONDITION: the capture must HAVE a companion Task created by the running user, '
            + 'or this proves only that a companion-less message is skipped');
        Assert.areEqual(0, writeCount,
            'A capture whose companion was created by a real user is a deliberate send. Its '
            + 'RelatedToId is explicit human intent and must never reach the writer');
        Assert.isTrue(recorder.recorded.isEmpty(),
            'and the trigger-driven pass at stopTest — which runs with the seam still OFF — must '
            + 'not write it either');
    }

    /**
     * A capture whose thread anchors NOTHING exits before the companion read — the common
     * case in any real batch, and the reason that early exit exists.
     *
     * ⚠ VACUITY FIX: asserts the recorder got NOTHING, alongside the cost assertions.
     */
    @isTest
    static void captureWithNoAnchorAnywhere_isLeftAloneCheaply() {
        Lead broker = TestDataFactory.createLead(true);
        EmailMessage capture = insertCapture(broker.Id, NEW_CONVO, NEW_CONVO, null);

        RecordingWriter recorder = useRecordingWriter();
        EmailThreadAdopterService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadAdopterService.run(new Set<Id>{ capture.Id });
        Integer writeCount = recorder.recorded.size();     // snapshot — see class header
        Integer queryCount = EmailThreadAdopterService.lastRunQueryCount;
        Test.stopTest();

        Assert.areEqual(0, writeCount,
            'An unanchored capture must never reach the writer');
        Assert.isTrue(recorder.recorded.isEmpty(),
            'and the trigger-driven pass at stopTest must not write it either');
        // The QUERY assertion below stays and is non-vacuous: the double replaces DML only, so
        // SOQL counts are unaffected by it. (A DML assertion here would be 0 by construction.)
        Assert.areEqual(2, queryCount,
            'and must cost only the message read plus the anchor read: with no anchors matched '
            + 'there is nothing to fingerprint, so the companion read must be skipped entirely');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // D5 — CONVERGENCE, decomposed into "writes once" and "then writes nothing"
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * D5 first half — an unconverged capture produces EXACTLY ONE write, through the
     * double so the decision is observable.
     */
    @isTest
    static void firstPassRecordsExactlyOneWrite() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        insert anchorOnWhat(deal.Id, DEAL_ROOT);
        Lead broker = TestDataFactory.createLead(true);
        EmailMessage capture = insertCapture(broker.Id, DEAL_ROOT, REPLY_ID, null);

        RecordingWriter recorder = useRecordingWriter();
        EmailThreadAdopterService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadAdopterService.run(new Set<Id>{ capture.Id });
        // Snapshot INSIDE the block — see the class header. The trigger-enqueued
        // EmailCaptureQueueable runs at stopTest() and, because the double never commits,
        // legitimately decides to write this capture AGAIN, so the recorder accumulates a
        // second row. This is a per-decision-pass count and must be read per pass.
        Integer writeCount = recorder.recorded.size();
        Id writtenTarget = recorder.targetFor(capture.Id);
        Integer dmlStatements = EmailThreadAdopterService.lastRunDmlStatements;
        Test.stopTest();

        Assert.areEqual(1, writeCount,
            'An unconverged, anchored, fingerprinted capture must produce exactly ONE write');
        Assert.areEqual(deal.Id, writtenTarget, 'pointed at anchor truth');
        Assert.areEqual(0, dmlStatements,
            'and ZERO real DML, because the double is what received it. The "one write is ONE '
            + 'bulk DML statement" property belongs where the REAL writer runs and is pinned by '
            + 'adopterAt251Captures_isBulkSafe (1 list-update = 1 statement even when every row '
            + 'is refused) and by the quirk canary. Asserting 1 here could never pass — it is '
            + 'the seam working as designed. A NON-zero value here means someone reintroduced a '
            + 'direct Database.update into commitAdoptions alongside the writer');
    }

    /**
     * 🔴 D4 ROW 3 + D5 second half — CONVERGENCE, and deliberately WITHOUT the double.
     *
     * `RelatedToId` is seeded to anchor truth AT INSERT (measured to persist), which is
     * genuinely the already-adopted state — so the real writer is never reached and the
     * zero is produced by the DECISION, not by the platform refusing anything. That is
     * what makes re-runs, EAC re-syncs and overlapping backfill windows free, and why this
     * feature ships no rollback code, no marker field and no Finalizer.
     *
     * ⚠ The seam stays ON so convergence is isolated: with it off the pass would also
     * write nothing, but for the WRONG reason (adoption churns the companion Task, so an
     * adopted capture loses the EAC fingerprint — invariant F3).
     *
     * ⚠ NOT EXPOSED to the trigger-driven pass that runs at `stopTest()`, and this was
     * checked rather than assumed: that pass reaches the SAME converged decision (the row
     * already carries anchor truth), so it writes nothing and cannot mutate the seeded
     * state. Even if it somehow decided to write, the real writer is installed here and
     * the platform refuses. The counters are snapshotted regardless, because the trigger
     * pass would still overwrite the statics.
     */
    @isTest
    static void adoptionIsConvergent_secondPassWritesNothing() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        insert anchorOnWhat(deal.Id, DEAL_ROOT);
        Lead broker = TestDataFactory.createLead(true);
        EmailMessage capture = insertCapture(broker.Id, DEAL_ROOT, REPLY_ID, deal.Id);

        EmailThreadAdopterService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadAdopterService.run(new Set<Id>{ capture.Id });
        Integer dmlStatements = EmailThreadAdopterService.lastRunDmlStatements;
        Integer adoptedCount = EmailThreadAdopterService.lastRunAdoptedCount;
        List<String> failures = EmailThreadAdopterService.lastRunFailureCodes;
        Test.stopTest();

        Assert.areEqual(deal.Id,
            [SELECT RelatedToId FROM EmailMessage WHERE Id = :capture.Id].RelatedToId,
            'Precondition: insert-time seeding must have persisted anchor truth onto the row, '
            + 'or this is not a convergence scenario at all');
        Assert.areEqual(0, dmlStatements,
            'A converged capture must spend ZERO DML. A pass that still writes would churn the '
            + 'companion Task on every EAC re-sync for no state change');
        Assert.areEqual(0, adoptedCount, 'and report nothing adopted');
        Assert.isTrue(failures.isEmpty(),
            'and must not even ATTEMPT a write — a non-empty failure list here would mean the '
            + 'convergence check did not fire and the platform blocked it instead');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // THE PLATFORM QUIRK — pinned by its ERROR, on the real writer
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 THE QUIRK CANARY, AND IT IS TWO-WAY. On a row the decision logic DID select, the
     * real writer is used and the platform's refusal is asserted BY ITS ERROR CODE — not
     * by a zero count, which "nothing happened" would also satisfy.
     *
     * It goes RED in BOTH directions, and both are the point:
     *   • a DIFFERENT failure (validation rule, FLS, lock) means something changed that
     *     this feature has not accounted for — investigate, do not relax the assertion;
     *   • **the platform starting to PERMIT the update** — the failure list goes empty and
     *     `lastRunAdoptedCount` becomes 1. That is GOOD NEWS: at that point the seam is no
     *     longer needed for these paths and the committed-state assertions
     *     (`RelatedToId == deal.Id` after the run) can and should be restored across this
     *     class, with this test retired.
     *
     * Runtime behaviour is the opposite of this and is not in question — the write
     * committed twice on `usman-dpeg` against real capture `02siw0000005prVAAQ`.
     */
    @isTest
    static void platformRefusesTheRelatedToIdUpdate_isTheDocumentedQuirk() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        insert anchorOnWhat(deal.Id, DEAL_ROOT);
        Lead broker = TestDataFactory.createLead(true);
        EmailMessage capture = insertCapture(broker.Id, DEAL_ROOT, REPLY_ID, null);

        // NO double — this is the one test that must meet the real platform.
        EmailThreadAdopterService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadAdopterService.run(new Set<Id>{ capture.Id });
        Integer dmlStatements = EmailThreadAdopterService.lastRunDmlStatements;
        Integer adoptedCount = EmailThreadAdopterService.lastRunAdoptedCount;
        List<String> failures = EmailThreadAdopterService.lastRunFailureCodes;
        Test.stopTest();

        Assert.areEqual(1, dmlStatements,
            'Precondition: the decision must have SELECTED this row and attempted one write — '
            + 'otherwise the refusal below proves nothing about the platform');
        Assert.areEqual(1, failures.size(), 'Exactly one row must have been refused');
        Assert.isTrue(failures[0].contains(REFUSAL_CODE),
            'The refusal must be ' + REFUSAL_CODE + ' on RelatedToId. Actual: ' + failures[0]
            + ' — a DIFFERENT error means something new is blocking the write; an EMPTY list '
            + 'means the platform now permits it and the committed-state assertions should be '
            + 'restored (see this method Javadoc)');
        Assert.areEqual(0, adoptedCount,
            'and nothing may be counted as adopted while the platform refuses');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CROSS-FEATURE — the P6 regression, decomposed from the write
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 THE P6 REGRESSION — THE REASON THE GUARD AMENDMENT EXISTS, now testing the
     * WIDENING INDEPENDENTLY OF THE WRITE.
     *
     * ⚠ WHY IT WAS DECOMPOSED (finding 3 of the 2026-08-02 deploy). The previous version
     * seeded `RelatedToId = null` and relied on the adopter to populate it. When the write
     * proved impossible in this context the capture stayed unanchored, the guard deleted
     * it, and the test failed — meaning the ∪-`RelatedToId` leg of guard 4 **never
     * executed against a populated value at all**. Coupling the two concerns left the
     * widening with zero coverage.
     *
     * Shape: an outbound reply in a deal thread, EAC-related to the broker's Lead (which
     * carries NO anchor), with `RelatedToId` seeded AT INSERT to the anchored Opportunity
     * — exactly the state a completed adoption leaves behind. The guard must KEEP it, and
     * can only do so through the widened leg.
     *
     * The unanchored `noise` capture on the SAME Lead is the negative control: it must
     * still be deleted, proving the guard ran a real deletion pass.
     */
    @isTest
    static void adoptedCaptureIsKeptByTheGuard_viaTheRelatedToIdLeg() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        insert anchorOnWhat(deal.Id, DEAL_ROOT);
        Lead unrelatedBroker = TestDataFactory.createLead(true); // carries NO anchor at all
        EmailMessage adopted = insertCapture(
            unrelatedBroker.Id, bracketed(DEAL_ROOT), bracketed(REPLY_ID), deal.Id);
        EmailMessage noise = insertCapture(unrelatedBroker.Id, NEW_CONVO, NEW_CONVO, null);

        EmailThreadAdopterService.treatAllAsMaterialized = true;
        EmailThreadGuardService.treatAllAsMaterialized = true;
        Test.startTest();
        System.enqueueJob(new EmailCaptureQueueable(new Set<Id>{ adopted.Id, noise.Id }));
        Test.stopTest();

        Assert.areEqual(deal.Id,
            [SELECT RelatedToId FROM EmailMessage WHERE Id = :adopted.Id].RelatedToId,
            'Precondition: the adopted state must be seeded on the row, or the widened leg has '
            + 'nothing to match and this test proves nothing');
        Assert.areEqual(1, [SELECT COUNT() FROM EmailMessage WHERE Id = :adopted.Id],
            'An Opportunity-anchored capture must SURVIVE the guard. It is anchored on no Lead '
            + 'it lives on, so ONLY the widened guard 4 (related Leads UNION the RelatedToId '
            + 'record) can keep it — revert that widening and this goes red');
        Assert.areEqual(0, [SELECT COUNT() FROM EmailMessage WHERE Id = :noise.Id],
            'NEGATIVE CONTROL: the unanchored capture on the same Lead must still be deleted, '
            + 'or the guard was inert and the survival above proves nothing');
    }

    /**
     * BULK SAFETY at the volume EAC produces, driven through the REAL trigger path and
     * deliberately keeping the REAL writer.
     *
     * ⚠ WHY THE REAL WRITER SURVIVES THE QUIRK HERE: `Database.update` on a list is ONE
     * DML statement whether the rows commit or are refused, so the exactly-1-statement and
     * constant-query-budget assertions are untouched by the refusal — and the refusal
     * codes double as proof that the decision SELECTED those rows rather than silently
     * skipping them. Running this through the double would test the double.
     *
     * ⚠ THE GUARD SEAM IS OFF ON PURPOSE. With adoption unable to land, an adopted capture
     * is not anchored on anything it lives on, so a live guard would delete all 251 and
     * this test would measure the guard instead of the adopter. Seam off ⇒ companions look
     * like human sends ⇒ guard 3 blocks every deletion.
     */
    @isTest
    static void adopterAt251Captures_isBulkSafe() {
        final Integer volume = 251;
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        insert anchorOnWhat(deal.Id, DEAL_ROOT);
        Lead broker = TestDataFactory.createLead(true);

        List<EmailMessage> captures = new List<EmailMessage>();
        for (Integer i = 0; i < volume; i++) {
            captures.add(buildCapture(
                bracketed(DEAL_ROOT), bracketed('bulk-' + i + '@mail.example.invalid'), null));
        }

        EmailThreadAdopterService.treatAllAsMaterialized = true;
        EmailThreadGuardService.treatAllAsMaterialized = false;

        Test.startTest();
        insert captures; // ONE bulk DML — the shape EAC uses; fires the trigger twice
        List<EmailMessageRelation> relations = new List<EmailMessageRelation>();
        for (EmailMessage capture : captures) {
            relations.add(new EmailMessageRelation(
                EmailMessageId = capture.Id, RelationId = broker.Id, RelationType = 'ToAddress'));
        }
        insert relations; // EAC writes these AFTER the messages, in the same transaction
        Test.stopTest();  // both enqueued EmailCaptureQueueable jobs run here

        Set<Id> captureIds = new Map<Id, EmailMessage>(captures).keySet();
        Assert.areEqual(volume, [SELECT COUNT() FROM EmailMessage WHERE Id IN :captureIds],
            'All ' + volume + ' captures must survive: the guard seam is off, so nothing may be '
            + 'deleted and the measurement is purely of the adopter');
        Assert.areEqual(1, EmailThreadAdopterService.lastRunDmlStatements,
            'The adopter must write ONE bulk DML statement regardless of volume — one statement '
            + 'covers every row in the chunk whether the platform accepts them or not');
        Assert.isFalse(EmailThreadAdopterService.lastRunFailureCodes.isEmpty(),
            'and the decision must have SELECTED rows to write: an empty failure list here means '
            + 'nothing was even attempted, which at this volume is a bulkification regression '
            + 'rather than the documented platform refusal');
        Assert.isTrue(EmailThreadAdopterService.lastRunFailureCodes[0].contains(REFUSAL_CODE),
            'and every refusal must be the documented quirk, not a new error. Actual: '
            + EmailThreadAdopterService.lastRunFailureCodes[0]);
        Assert.isTrue(EmailCaptureQueueable.lastRunQueryCount <= QUEUEABLE_QUERY_BUDGET,
            'GOVERNOR HEADROOM: one execution consumed '
            + EmailCaptureQueueable.lastRunQueryCount + ' queries against a budget of '
            + QUEUEABLE_QUERY_BUDGET + '. The budget is CONSTANT (anchor index 2, adopter 2, '
            + 'guard 3) and must not scale with the number of captures');
        Assert.isTrue(EmailCaptureQueueable.lastRunQueryCount > 0,
            'Precondition: the queueable must actually have run, or the budget assertion is '
            + 'vacuous');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Entry points / guard clauses / re-run safety
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * THE SWEEP ENTRY POINT. `run(Set<Id>)` is what DevOps calls from anonymous Apex over
     * a date window, and it must build its own anchor index. Chunk at <= 1,000 Ids,
     * LAST_N_DAYS:1 first, and always ADOPTER BEFORE GUARD — a guard sweep run first
     * deletes captures this would have rescued, and that is not recoverable.
     */
    @isTest
    static void sweepEntryPoint_buildsItsOwnIndexAndSelectsTheDeal() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        insert anchorOnWhat(deal.Id, DEAL_ROOT);
        Lead broker = TestDataFactory.createLead(true);
        EmailMessage capture = insertCapture(broker.Id, DEAL_ROOT, REPLY_ID, null);

        RecordingWriter recorder = useRecordingWriter();
        EmailThreadAdopterService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadAdopterService.run(new Set<Id>{ capture.Id }); // no shared index supplied
        Set<Id> writtenIds = recorder.recordedIds();       // snapshot — see class header
        Integer writeCount = recorder.recorded.size();
        Id writtenTarget = recorder.targetFor(capture.Id);
        Test.stopTest();

        Assert.areEqual(new Set<Id>{ capture.Id }, writtenIds,
            'The one-argument sweep entry point must build its own anchor index and reach the '
            + 'same decision the queueable path reaches');
        Assert.areEqual(1, writeCount, 'exactly once');
        Assert.areEqual(deal.Id, writtenTarget,
            'pointed at the Opportunity the anchor names');
    }

    /**
     * Null input is a silent no-op. The sweep passes whatever a date-window query
     * returned, which is legitimately nothing on a quiet day.
     */
    @isTest
    static void runWithNullIds_isASilentNoOp() {
        RecordingWriter recorder = useRecordingWriter();
        Test.startTest();
        EmailThreadAdopterService.run(null);
        Test.stopTest();

        Assert.isTrue(recorder.recorded.isEmpty(), 'A null Id set must write nothing');
        Assert.areEqual(0, EmailThreadAdopterService.lastRunAdoptedCount, 'and adopt nothing');
        Assert.areEqual(0, EmailThreadAdopterService.lastRunQueryCount,
            'and must not spend a query finding that out');
    }

    /**
     * Empty input, tested separately from null: they reach the guard clause by different
     * routes and a refactor can fix one while breaking the other.
     */
    @isTest
    static void runWithEmptyIds_isASilentNoOp() {
        RecordingWriter recorder = useRecordingWriter();
        Test.startTest();
        EmailThreadAdopterService.run(new Set<Id>());
        Test.stopTest();

        Assert.isTrue(recorder.recorded.isEmpty(), 'An empty Id set must write nothing');
        Assert.areEqual(0, EmailThreadAdopterService.lastRunQueryCount,
            'and must not spend a query');
    }

    /**
     * Re-running over Ids whose rows the guard already deleted must be silent, not an
     * exception. This is the shape of a sweep re-run over an overlapping window, and of a
     * live pass racing an EAC delete.
     */
    @isTest
    static void runOverAlreadyDeletedRows_isASilentNoOp() {
        Lead broker = TestDataFactory.createLead(true);
        EmailMessage capture = insertCapture(broker.Id, DEAL_ROOT, REPLY_ID, null);
        Id goneId = capture.Id;
        delete capture;

        RecordingWriter recorder = useRecordingWriter();
        EmailThreadAdopterService.treatAllAsMaterialized = true;
        Test.startTest();
        EmailThreadAdopterService.run(new Set<Id>{ goneId });
        Integer writeCount = recorder.recorded.size();     // snapshot — see class header
        Test.stopTest();

        Assert.areEqual(0, writeCount,
            'Ids whose rows are already gone must drop out of the initial read and write '
            + 'nothing — re-running a sweep over an overlapping window must never throw');
        Assert.isTrue(recorder.recorded.isEmpty(),
            'and the trigger-driven pass at stopTest, which sees the same deleted row, must not '
            + 'write either');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @param identifier A bare RFC identifier.
     * @return It in the BRACKETED form EAC supplies.
     */
    private static String bracketed(String identifier) {
        return '<' + identifier + '>';
    }

    /**
     * An unsaved capture in the shape EAC materializes.
     *
     * @param threadId    RFC Message-ID of the thread root.
     * @param messageId   RFC Message-ID of this message.
     * @param relatedToId What EAC already decided this email is about; nullable. Set at
     *                    INSERT because that is the only time this field accepts a value.
     * @return The unsaved EmailMessage.
     */
    private static EmailMessage buildCapture(String threadId, String messageId, Id relatedToId) {
        return new EmailMessage(
            Subject = 'captured',
            Status = '3',
            Incoming = false,
            ThreadIdentifier = threadId,
            MessageIdentifier = messageId,
            RelatedToId = relatedToId,
            FromAddress = 'junior@example.invalid',
            ToAddress = 'adopt.broker@example.invalid'
        );
    }

    /**
     * Inserts one capture, relates it to a Lead the way EAC does, and re-reads it so the
     * platform-stamped ActivityId is available.
     *
     * ⚠ ORDER IS LOAD-BEARING (measured facts 1 and 2 in the class header): ActivityId is
     * stamped only once the message relates to a record, and every new relation DELETES
     * and RECREATES the companion Task. So the relation goes in FIRST and ActivityId is
     * read LAST. The assertion fails loud if Enhanced Email is ever switched off.
     *
     * @param leadId      Lead to associate via EmailMessageRelation; required.
     * @param threadId    RFC Message-ID of the thread root.
     * @param messageId   RFC Message-ID of this message.
     * @param relatedToId Seeded at insert; nullable.
     * @return The re-read EmailMessage with ActivityId populated.
     */
    private static EmailMessage insertCapture(
            Id leadId, String threadId, String messageId, Id relatedToId) {
        EmailMessage capture = buildCapture(threadId, messageId, relatedToId);
        insert capture;
        insert new EmailMessageRelation(
            EmailMessageId = capture.Id, RelationId = leadId, RelationType = 'ToAddress');
        EmailMessage stored = [
            SELECT Id, ActivityId, RelatedToId, ThreadIdentifier, MessageIdentifier
            FROM EmailMessage
            WHERE Id = :capture.Id
        ];
        Assert.isNotNull(stored.ActivityId,
            'PRECONDITION FAILED: Enhanced Email must auto-create the companion Task and stamp '
            + 'EmailMessage.ActivityId. A null ActivityId means Enhanced Email is disabled in '
            + 'this org — the adopter cannot fingerprint anything without it, and every '
            + 'fingerprint test in this class would pass vacuously');
        return stored;
    }

    /**
     * An unsaved pipeline thread anchor on a WHAT — the post-conversion shape standard
     * conversion produces by itself (experiment E1), and the only shape the resolution
     * chain acts on.
     *
     * ⚠ Task.Type is deliberately absent and must stay absent: it does not exist in this
     * org, compiles anyway, and throws at runtime (see InboundEmailActivityService).
     *
     * @param whatId    The Opportunity the anchor sits on.
     * @param threadKey Conversation-root Message-ID, stored UNBRACKETED as the pipeline
     *                  writes it.
     * @return The unsaved anchor Task.
     */
    private static Task anchorOnWhat(Id whatId, String threadKey) {
        return new Task(
            WhatId = whatId,
            Subject = 'Email: deal',
            Status = 'Completed',
            TaskSubtype = 'Email',
            Thread_Key__c = threadKey,
            Inbound_Message_Id__c = threadKey
        );
    }

    /**
     * An unsaved pipeline thread anchor on a WHO — the pre-conversion shape, and (after
     * conversion repoints it) the Contact shape the chain must fail closed on.
     *
     * @param whoId     Lead or Contact the anchor sits on.
     * @param threadKey Conversation-root Message-ID.
     * @return The unsaved anchor Task.
     */
    private static Task anchorOnWho(Id whoId, String threadKey) {
        return new Task(
            WhoId = whoId,
            Subject = 'Email: deal',
            Status = 'Completed',
            TaskSubtype = 'Email',
            Thread_Key__c = threadKey,
            Inbound_Message_Id__c = threadKey
        );
    }
}
