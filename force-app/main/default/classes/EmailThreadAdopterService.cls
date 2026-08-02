/**
 * EAC THREAD ADOPTER — the MIRROR IMAGE of the EAC Thread Guard (added 2026-08-02).
 * This class owns the adopt DECISION and the only `EmailMessage.RelatedToId` DML in
 * the feature; EmailCaptureQueueable is a thin async wrapper that runs it, and
 * EmailThreadAnchorService supplies the thread truth both halves share.
 *
 *   • EmailThreadGuardService    DELETES a capture anchored NOWHERE it lives.
 *   • EmailThreadAdopterService  ASSOCIATES an anchored capture onto the deal record
 *                                Einstein Activity Capture failed to reach.
 *
 * ═══ THE PROBLEM ═══
 * EAC is the ONLY system that ever sees the OUTBOUND half of a deal conversation — the
 * Broker Protection pipeline receives inbound mail through a forwarding address and
 * nothing else. But EAC associates by ADDRESS ALONE, so an outbound reply to a broker
 * lands on whatever record carries that broker's address (a Lead, a Contact, sometimes
 * an Opportunity it inferred through the matched Contact) — NOT on the deal the thread
 * actually belongs to. The result is half a conversation on the deal record, which is
 * exactly the gap the user asked to close: "majority of the discussion will happen in
 * opportunity".
 *
 * ═══ THE RULE ═══
 * A capture may be adopted onto an Opportunity ONLY when the Broker Protection pipeline
 * itself anchored that thread there — `Task.Thread_Key__c` / `Task.Inbound_Message_Id__c`
 * on an anchor Task whose `WhatId` IS that Opportunity. That is an RFC-header IDENTITY
 * match, and it is strictly better evidence than the address inference EAC used; the
 * inbound pipeline already resolves this way ("a header match is PROOF… a classifier's
 * read of the body is an opinion"). Everything else fails closed and is left untouched.
 *
 * ═══ 🔴 D4 — THE CONTENTION POLICY, EXACTLY AS BUILT ═══
 * `RelatedToId` holds ONE Id and EAC has usually already written something into it, so
 * this table IS the feature. Read it before changing any branch of `adopt(...)`:
 *
 *   | current RelatedToId              | anchor resolves an Opportunity | action        |
 *   | -------------------------------- | ------------------------------ | ------------- |
 *   | null                             | yes                            | WRITE it      |
 *   | an Opportunity, different         | yes                            | OVERWRITE     |
 *   | an Opportunity, equal             | yes                            | NO-OP         |
 *   | a NON-Opportunity (Account, Case…) | yes                            | LEAVE ALONE   |
 *   | anything                         | no                             | LEAVE ALONE   |
 *
 *   • OVERWRITING AN OPPORTUNITY IS THE POINT, not an oversight. Measured on the two
 *     live captures in `usman-dpeg` (finding F2): EAC arrives with `RelatedToId` = an
 *     Opportunity it inferred THREAD-BLINDLY through a matched Contact. That is the same
 *     class of lie the guard deletes. Leaving it in place is WORSE than showing nothing —
 *     a plausible-looking email on the wrong deal.
 *   • A NON-OPPORTUNITY VALUE IS NEVER TOUCHED. Same allow-list direction as the guard's
 *     W1 fix: an unanticipated object type falls through to "don't touch", not to
 *     "overwrite". `RelatedToId` accepts ~80 types in this org (Account, Case, Contract,
 *     Property__c, Transaction__c, …); this feature claims exactly one of them.
 *   • NULL IS NEVER WRITTEN. There is no branch that clears the field. A capture the
 *     chain cannot resolve keeps whatever EAC decided.
 *   • THE EAC FINGERPRINT IS REQUIRED (companion `Task.CreatedBy.UserType ==
 *     'AutomatedProcess'`, the same test guard 3 makes). A composer / Agentforce send's
 *     `RelatedToId` was chosen by a HUMAN; overwriting it would override explicit intent.
 *
 * ═══ 🔴 D5 — ADOPTION IS CONVERGENT, SO THERE IS NO ROLLBACK STORY ═══
 * The target state is a PURE FUNCTION of (thread anchors, capture identifiers): a re-run
 * recomputes the same Opportunity and writes only on difference. Re-runs, EAC re-syncs,
 * partial failures and overlapping backfill windows all converge to anchor truth, and the
 * second pass performs ZERO DML (`adoptionIsConvergent_secondPassWritesNothing` pins
 * this). Nothing here ever needs undoing — which is why no compensating code, no
 * "adopted" marker field and no Finalizer exist in this feature.
 *
 * Three invariants follow, and they are invariants rather than preferences:
 *
 *   1. **NO TASK DML, EVER.** The only DML this class performs is on
 *      `EmailMessage.RelatedToId`. Measured (experiment E2): the platform PROPAGATES that
 *      value onto the companion Task's `WhatId` by itself, and that companion is what
 *      renders on the Opportunity's Activity timeline — so the visible effect is free.
 *      Writing a Task here would also destroy the guard's structural guarantee that
 *      Broker Protection's own anchor Tasks are unreachable (see EmailThreadGuardService's
 *      header); that guarantee is worth more than any convenience a Task write could buy.
 *   2. **FINGERPRINT LOSS IS ONE-WAY AND ACCEPTED (F3).** Adoption churns the companion
 *      Task — the platform deletes and recreates it, created by the DML user, never by
 *      Automated Process — so an adopted capture permanently loses the EAC fingerprint
 *      and is ADOPTED ONCE. The direction is safe: an adopted capture is anchored on its
 *      `RelatedToId` record and the guard keeps it on two independent grounds (guard 3
 *      fails AND guard 4 holds). The known limitation is L2: if EAC ever re-points
 *      `RelatedToId` IN PLACE on an existing row, this class will not re-adopt it. Remedy
 *      is the one-off sweep, same shape as the guard's. If EAC re-INSERTS the capture
 *      instead, the fingerprint is fresh and the feature self-heals normally.
 *   3. **THE ADOPTER RUNS BEFORE THE GUARD, and the guard's re-read is what makes that
 *      work.** Running the guard first would delete an Opportunity-anchored capture
 *      (related only to an unrelated same-address Lead) seconds before the adopter ever
 *      saw it — finding P6. Because the guard re-reads the messages through
 *      `EmailMessageSelector.selectByIds`, it observes the `RelatedToId` this class just
 *      wrote and keeps the row via its widened guard 4. Pinned by
 *      `adoptedCaptureSurvivesAFullAdopterThenGuardPass`.
 *
 * ═══ WHAT THIS CLASS DELIBERATELY DOES NOT DO ═══
 *   • No `EmailMessageRelation` inserts (D1). v1 adopts onto Opportunity via
 *     `RelatedToId` only; the Lead outbound-half is deferred to an OBSERVED gap.
 *   • No per-anchor `PropertyMatchingService.resolveLiveRecord(...)` call. It reads
 *     `LeadSelector.selectConversionById` per Id, so calling it per anchor would be
 *     SOQL-in-a-loop — forbidden outright by `.claude/rules/apex-layering-rule.md`. The
 *     resolution chain lives in EmailThreadAnchorService and is a MAP LOOKUP; see that
 *     class's header for why experiment E1 retired the conversion step entirely.
 *   • No Lead / Contact / Task writes of any kind.
 *
 * ═══ LAYER / SHARING ═══
 * Service (ARCHITECTURE.md §2). All SOQL delegates to `EmailMessageSelector` and
 * `TaskSelector`; this class contains none.
 *
 * `without sharing` justification (ARCHITECTURE.md §2 standard; precedent:
 * EmailThreadGuardService, ApprovalAuditService, BrokerPortalService): this runs in a
 * wholly automated context as whichever principal Einstein Activity Capture committed
 * under — never as a human with a considered view of these records — and that principal
 * holds none of this repo's permission sets. It must adopt onto EVERY Opportunity the
 * anchors resolve, not the subset that principal happens to have sharing to; a
 * `with sharing` version would produce exactly the half-complete deal threads this
 * feature exists to prevent. The elevated scope is narrow and one-directional: the only
 * rows it can write are EAC-fingerprinted captures whose thread the pipeline ITSELF
 * anchored, and the only value it can write is an Opportunity Id that came from that
 * anchor.
 *
 * ═══ 🔴 PLATFORM QUIRK — `EmailMessage.RelatedToId` AND ITS LYING DESCRIBE ═══
 * ⚠ **`describe.updateable` reports TRUE for this field AND IT IS WRONG.** That flag is
 * what let this feature reach a deploy before the problem surfaced. Do not trust it, do
 * not "verify" this field by describing it again, and do not treat a green describe as
 * evidence that a write will land — repeating that check is repeating the mistake.
 *
 * What is actually established, and it is a CORRELATION rather than a mechanism:
 *
 *   • **The write DOES work at runtime.** Committed TWICE on `usman-dpeg` 2026-08-02
 *     against real EAC capture `02siw0000005prVAAQ` (spike experiment 3a: set, then
 *     revert, each readback-confirmed). The mechanism this feature is built on is real.
 *   • **The write CANNOT be committed against a test-created capture inside `@isTest`.**
 *     Seven probes plus the failed deploy's fingerprint: every attempt returns
 *     `INSUFFICIENT_ACCESS_OR_READONLY — "You cannot edit this field" — fields=(RelatedToId)`.
 *     Probed independent of message Status (Sent AND Draft both refused), independent of
 *     any `EmailMessageRelation`, and NOT a whole-record lock — `Subject` updates fine on
 *     the same row.
 *   • **Which variable is the mechanism is NOT determined.** The two runs differ in more
 *     than one way at once — test context vs runtime, AND test-created row vs real
 *     EAC-materialized row. Nothing here isolates them, so nothing here should be quoted
 *     as "test context blocks it" or "test-created rows block it". Both remain open.
 *   • **INSERT-time seeding persists.** Setting `RelatedToId` on insert works and the
 *     value survives (measured). Tests rely on this to stage already-adopted state.
 *   • **Residual:** the runtime proof ran as an admin, while production runs as whichever
 *     principal EAC committed under. The recurring L-check (see R1) is what closes that
 *     gap; until it reports adoptions, "it works at runtime" means "it worked for an
 *     admin".
 *
 * Consequence for this class: the DML is wrapped in the `AdoptionWriter` seam below so
 * tests can assert the DECISION (which rows, which target) separately from the
 * platform's acceptance of the write. The decision logic itself is never injectable.
 *
 * ═══ 🔴 R1 — THIS FEATURE FAILS SOFT, SO WATCH FOR SILENCE ═══
 * `allOrNone = false` plus a `System.debug` is the entire failure surface. If the runtime
 * write is ever blocked the way the test context blocks it, the result is ZERO adoptions
 * and NO durable signal: no exception, no failed `AsyncApexJob`, no record anywhere. The
 * symptom to watch is **"adoptions = 0 across a period in which real EAC captures
 * arrived"**, and the L-check that detects it is RECURRING, not a one-off launch gate.
 * `lastRunFailureCodes` below is in-transaction only and does not survive the job.
 *
 * ═══ DML MODEL — plain `Database.update` (system mode). READ THIS BEFORE "FIXING" IT ═══
 * `AccessLevel.USER_MODE` is intentionally NOT applied, matching the established module
 * pattern (`EmailThreadGuardService`, `EmailToLeadService`, `InboundEmailStagingService`,
 * `PropertyClaimService`). PMD's `ApexCRUDViolation` flags the update below; the finding
 * is **accepted, not overlooked**, on the same grounds the sibling services record:
 *
 *   • There is no interactive user whose FLS/CRUD is meaningful to enforce. USER_MODE
 *     would not "enforce a user's intent" here — it would abort the adoption for
 *     everyone, silently, exactly as it would abort the guard.
 *   • The blast radius is closed BY CONSTRUCTION rather than by permissions: one field,
 *     on rows that satisfy the fingerprint test, to a value produced by an anchor the
 *     pipeline wrote. Nothing else is reachable from here.
 *   • `allOrNone = false` mirrors the guard's posture: one stubborn row (a capture EAC
 *     deleted mid-flight, a locked record) must not abandon the rest of the batch.
 *
 * This project has no `UnitOfWork` class (verified 2026-07-24), so service-layer DML is
 * direct by convention.
 *
 * ═══ ⚠ THE COMPANION/FINGERPRINT BLOCK IS DUPLICATED FROM THE GUARD ON PURPOSE ═══
 * CPD flags `companionFor` / `companionTasks` / `isEacMaterialized` as a copy of
 * EmailThreadGuardService's. Extracting them into a shared helper is NOT a safe tidy-up:
 * the TEST SEAM is what makes the fingerprint path reachable at all, and each service
 * owns its own. Twelve deployed guard tests set `EmailThreadGuardService
 * .treatAllAsMaterialized`; moving the fingerprint test behind a shared class would leave
 * those tests setting a flag that no longer gates anything — they would keep passing while
 * testing nothing. The duplication buys independent, honestly-testable seams for a
 * DESTRUCTIVE feature and an ADDITIVE one, and that is worth more than the three methods
 * it costs. Revisit only alongside a deliberate rework of both suites.
 *
 * ═══ BULK / GOVERNOR SHAPE — NOT covered by the singleton exemption ═══
 * `.claude/rules/bulk-test-rule.md`'s per-transaction-singleton exemption does NOT apply,
 * for the guard's reason verbatim: this class is TRIGGER-DRIVEN and EAC BATCH-INSERTS its
 * captures, so `run()` legitimately receives hundreds of message Ids at once. Its query
 * budget is CONSTANT — one message read, one companion read, plus the shared anchor read
 * when it must build its own index — and its DML is ONE bulk statement regardless of
 * volume. `EmailThreadAdopterServiceTest.adopterAt251Captures_isBulkSafe` and the
 * `lastRun*` counters below are what keep it that way: a change that adds one query per
 * message fails in that test rather than in a live EAC batch.
 *
 * @see EmailThreadAnchorService.cls (the shared index, the normalization, the D2 chain)
 * @see EmailThreadGuardService.cls (the other half; runs AFTER this one)
 * @see EmailCaptureQueueable.cls (the async wrapper that runs both)
 * @see agent-output/design-requirements-eac-adopter.md (D1, D3, D4, D5, D7, P6, E1, E2)
 */
public without sharing class EmailThreadAdopterService {

    /** `CreatedBy.UserType` of the companion Task EAC materializes. The fingerprint. */
    private static final String USER_TYPE_AUTOMATED_PROCESS = 'AutomatedProcess';

    /**
     * THE DML BOUNDARY — the ONLY injectable seam in this class, and deliberately the
     * narrowest one that works: it receives exactly what `commitAdoptions` already
     * decided to write, POST-DECISION. `adopt(...)` and every D4 guard stay
     * non-injectable so the decision logic is always fully exercised by tests.
     *
     * It exists because of the platform quirk in the class header: the update cannot be
     * committed in `@isTest` context, so without a seam every positive-path test would
     * assert nothing (and — measured in the failed deploy of 2026-08-02 — every
     * NEGATIVE-path test was LATENTLY VACUOUS, "unchanged" passing because no write ever
     * lands, regardless of the guards).
     */
    public interface AdoptionWriter {
        /**
         * @param adoptions Captures to re-point; each carries Id + resolved Opportunity.
         * @return One SaveResult per row, in input order.
         */
        List<Database.SaveResult> write(List<EmailMessage> adoptions);
    }

    /**
     * Production behaviour: literally the call this class made before the seam existed.
     *
     * ⚠ NO SHARING KEYWORD, DELIBERATELY — PMD raises `ApexSharingViolations` here and the
     * finding is ACCEPTED, not overlooked. An inner class with no sharing declaration runs
     * in the sharing context of its CALLER, which is this `without sharing` service; that
     * is what keeps the DML identical to the pre-seam call. Annotating it `with sharing`
     * to silence the warning would silently narrow the write to the running user's
     * sharing — the exact behaviour the class header's `without sharing` justification
     * exists to prevent, and it would half-adopt threads with no error anywhere.
     */
    private class PlatformAdoptionWriter implements AdoptionWriter {
        public List<Database.SaveResult> write(List<EmailMessage> adoptions) {
            return Database.update(adoptions, false);
        }
    }

    /**
     * The live writer. Swapped ONLY by tests; production never reassigns it, so the
     * default above is the whole of production behaviour.
     */
    @TestVisible
    private static AdoptionWriter writer = new PlatformAdoptionWriter();

    /**
     * TEST SEAM — the exact analogue of `EmailThreadGuardService.treatAllAsMaterialized`,
     * and required for the same measured reason: the AutomatedProcess fingerprint CANNOT
     * be reproduced in a test (Tasks created in a test are owned by the running user), so
     * without this seam the adopt path is unreachable and every adoption test would pass
     * vacuously by never adopting anything.
     *
     * Deliberately NOT a permission, a custom setting, or anything reachable at runtime:
     * production behavior must depend solely on the real fingerprint.
     */
    @TestVisible
    private static Boolean treatAllAsMaterialized = false;

    /**
     * GOVERNOR COUNTERS — captured INSIDE the execution, which is the only place they
     * mean anything. `Test.stopTest()` restores the pre-test limit counters, so a
     * `Limits.getQueries()` assertion written after it is silently vacuous. Same pattern
     * and the same reason as `ExtractAddressQueueable.lastRunQueryCount`.
     *
     * `lastRunDmlStatements` is what the convergence test asserts is ZERO on a second
     * pass; `lastRunQueryCount` is the constant-budget assertion that makes a future
     * per-message query fail in the bulk test instead of in production.
     */
    @TestVisible
    private static Integer lastRunQueryCount = 0;
    @TestVisible
    private static Integer lastRunDmlStatements = 0;
    @TestVisible
    private static Integer lastRunAdoptedCount = 0;

    /**
     * `STATUSCODE: message` for every row the write REFUSED, newest run only. Populated
     * by `commitAdoptions`; empty on a clean run.
     *
     * Two jobs. It is what
     * `platformRefusesTheRelatedToIdUpdate_isTheDocumentedQuirk` asserts on — pinning the
     * quirk by its ERROR rather than by a zero count, so the test cannot be satisfied by
     * "nothing happened". And it is the only in-transaction evidence that the decision
     * logic SELECTED rows and the platform then refused them, which is otherwise
     * indistinguishable from "the decision selected nothing" (see R1 in the class header
     * — this feature fails soft by design).
     */
    @TestVisible
    private static List<String> lastRunFailureCodes = new List<String>();

    /**
     * Adopt anchored captures onto the Opportunity their thread belongs to. Idempotent
     * and convergent (D5) — safe to re-run over the same Ids as often as you like.
     *
     * Entry point for the ONE-OFF SWEEP (anonymous Apex, run by DevOps): it builds its
     * own anchor index. The live path uses the two-argument overload so the index is
     * built once per execution and shared with the guard.
     *
     * ⚠ SWEEP ORDER IS ADOPTER → GUARD, always. Running the guard sweep first over a
     * historical window deletes captures this pass would have rescued, and a deleted
     * EmailMessage is not recoverable in Salesforce (the mail survives only in the
     * mailbox). Chunk at ≤ 1,000 message Ids per call and start with LAST_N_DAYS:1.
     *
     * @param messageIds EmailMessage Ids to examine; null/empty is a no-op.
     * @example
     * EmailThreadAdopterService.run(new Map&lt;Id, EmailMessage&gt;(
     *     [SELECT Id FROM EmailMessage WHERE CreatedDate = LAST_N_DAYS:1 LIMIT 1000]).keySet());
     */
    public static void run(Set<Id> messageIds) {
        run(messageIds, null);
    }

    /**
     * The queueable entry point: identical semantics, but consuming the SHARED anchor
     * index (D3) so the anchor read happens ONCE per execution rather than once per
     * feature — which is also what makes the adopter and the guard normalize identifiers
     * IDENTICALLY BY CONSTRUCTION rather than by convention.
     *
     * Passing null is legal and is what the sweep path does; the index is then built here.
     *
     * @param messageIds  EmailMessage Ids to examine; null/empty is a no-op.
     * @param sharedIndex The pre-built anchor index, or null to build one.
     */
    public static void run(Set<Id> messageIds, EmailThreadAnchorService.AnchorIndex sharedIndex) {
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        lastRunAdoptedCount = adopt(messageIds, sharedIndex);
        lastRunQueryCount = Limits.getQueries() - queriesBefore;
        lastRunDmlStatements = Limits.getDmlStatements() - dmlBefore;
    }

    /**
     * The decision pass and the single bulk write. Split out of `run` so the counters
     * above wrap EVERY exit path, including the early ones.
     *
     * The five checks are ordered so each is cheap to reason about and so the two that
     * can never be relaxed come first: nothing is written when the chain fails to resolve
     * (never write null), and nothing is written onto a deliberate human send.
     *
     * @param messageIds  EmailMessage Ids to examine.
     * @param sharedIndex The pre-built anchor index, or null to build one.
     * @return The number of captures actually adopted (successful updates).
     */
    private static Integer adopt(
            Set<Id> messageIds, EmailThreadAnchorService.AnchorIndex sharedIndex) {
        if (messageIds == null || messageIds.isEmpty()) {
            return 0;
        }
        List<EmailMessage> messages = EmailMessageSelector.selectByIds(messageIds);
        if (messages.isEmpty()) {
            return 0;
        }
        EmailThreadAnchorService.AnchorIndex anchors = (sharedIndex != null)
            ? sharedIndex
            : EmailThreadAnchorService.index(messages);
        // Nothing anchored means nothing this feature can name a deal for. Exiting here
        // also keeps the companion read off the budget for the common no-match batch.
        if (anchors.isEmpty()) {
            return 0;
        }

        Map<Id, Task> companionsByTaskId = companionTasks(messages);

        List<EmailMessage> adoptions = new List<EmailMessage>();
        for (EmailMessage message : messages) {
            Id anchorTruth = anchors.resolveOpportunity(message);
            if (anchorTruth == null                                        // no deal to name
                || !isEacMaterialized(companionFor(message, companionsByTaskId)) // human send
                || !isAdoptableTarget(message.RelatedToId)                 // lives on something else
                || anchorTruth == message.RelatedToId) {                   // already converged
                continue;
            }
            adoptions.add(new EmailMessage(Id = message.Id, RelatedToId = anchorTruth));
        }
        return commitAdoptions(adoptions);
    }

    /**
     * D4's "current value" column: `RelatedToId` may be replaced only when it is empty or
     * already points at an Opportunity.
     *
     * ⚠ ALLOW-LIST, NOT A DENY-LIST, and that direction is the safety property: an
     * object type nobody anticipated falls through to "leave it alone". `RelatedToId`
     * accepts ~80 types in this org and this feature claims exactly one.
     *
     * @param currentRelatedToId Whatever EAC (or a human) already put there; nullable.
     * @return true when this class is permitted to overwrite it.
     */
    private static Boolean isAdoptableTarget(Id currentRelatedToId) {
        return currentRelatedToId == null
            || currentRelatedToId.getSObjectType() == Opportunity.SObjectType;
    }

    /**
     * The companion Task a capture names through `ActivityId` — the fingerprint carrier,
     * and the ONLY Task this class ever reads. It is never written and never deleted.
     *
     * @param message            The capture under examination.
     * @param companionsByTaskId Companion Tasks keyed by Task Id.
     * @return The companion Task, or null when the capture names none.
     */
    private static Task companionFor(EmailMessage message, Map<Id, Task> companionsByTaskId) {
        return (message.ActivityId == null) ? null : companionsByTaskId.get(message.ActivityId);
    }

    /**
     * Loads the companion Tasks the platform linked via `EmailMessage.ActivityId`. ONE
     * query for the whole batch, whatever its size.
     *
     * @param messages The captures under examination.
     * @return Companion Tasks (Id, CreatedBy.UserType) keyed by Task Id; empty when no
     *         message carries an ActivityId (never null).
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
     * Is this capture EAC's own work rather than a deliberate composer / Agentforce send?
     * A message with NO companion Task at all fails closed — it is not treated as
     * materialized, so nothing is written.
     *
     * `companion.CreatedBy` is dereferenced without a null check on purpose, exactly as in
     * EmailThreadGuardService: the only source of a companion Task is
     * `TaskSelector.selectByIds`, which selects `CreatedBy.UserType`, and `CreatedById` is
     * a system field that is never null on a queried row.
     *
     * @param companion The companion Task, or null when the message carries none.
     * @return true when the companion was created by the Automated Process user, or when
     *         the test seam is engaged.
     */
    private static Boolean isEacMaterialized(Task companion) {
        if (treatAllAsMaterialized) {
            return true;
        }
        return companion != null
            && USER_TYPE_AUTOMATED_PROCESS.equals(companion.CreatedBy.UserType);
    }

    /**
     * The ONE bulk write. Failures are logged rather than thrown so a single unwritable
     * row cannot abandon the rest of the batch — and because nothing here needs undoing:
     * the next pass simply recomputes the same target (D5).
     *
     * ⚠ TWO ACCEPTED STATIC-ANALYSIS FINDINGS LIVE ON THESE LINES, both deliberate and
     * both recorded on the sibling services:
     *   • `ApexCRUDViolation` — plain (system-mode) DML. Justified in the class header
     *     under DML MODEL; USER_MODE here would disable the feature, not secure it.
     *   • `AvoidDebugStatements` — this repo has no logging framework, and this is an
     *     ERROR path reached only when an update genuinely fails, not main-path
     *     instrumentation. Swallowing a `SaveResult` failure silently is the one outcome
     *     that would leave a deal thread half-adopted with nothing to explain it.
     *
     * @param adoptions Captures to re-point, each carrying Id + the resolved Opportunity;
     *                  empty-safe.
     * @return The number of rows that actually committed.
     */
    private static Integer commitAdoptions(List<EmailMessage> adoptions) {
        lastRunFailureCodes = new List<String>();
        if (adoptions.isEmpty()) {
            return 0;
        }
        Integer adopted = 0;
        for (Database.SaveResult result : writer.write(adoptions)) {
            if (result.isSuccess()) {
                adopted++;
            } else {
                for (Database.Error error : result.getErrors()) {
                    lastRunFailureCodes.add(error.getStatusCode() + ': ' + error.getMessage());
                }
                System.debug(LoggingLevel.WARN, 'EAC adopter update: ' + result.getErrors());
            }
        }
        return adopted;
    }
}
