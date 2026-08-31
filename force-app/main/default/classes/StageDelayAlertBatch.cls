/**
 * The daily stalled-deal reminder. Notifies the deal OWNER and the `Acquisition` queue once a deal
 * has been sitting in its stage past that stage's configured threshold — exactly ONCE per stage
 * occupancy. Design `agent-output/design-requirements.md` §2 ITEM 4.
 *
 * The third instance of a proven shape: `CallForOffersAlertBatch` (2026-08-14), then
 * `NdaExpiryAlertBatch` (2026-08-16), now this. Where a paragraph below is inherited rather than
 * newly derived, it says so.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 0. 🔴 WHAT SHIPPED IS THE IN-APP HALF ONLY. THE EMAIL HALF IS DEFERRED, NOT MISSED.
 *    READ THIS BEFORE FILING "THE REMINDER DOES NOT EMAIL" AS A DEFECT.
 * ═══════════════════════════════════════════════════════════════════════════
 * The requirement was delivery by **in-app custom notification AND email**, to the deal owner and
 * the Acquisition team. **Only the in-app half is built.** That is a DELIBERATE USER DECISION taken
 * on 2026-08-31, after the three findings below were put to the user — not an oversight, and not a
 * silent descope.
 *
 *   1. A CUSTOM NOTIFICATION CANNOT SEND EMAIL. `CustomNotificationType` exposes `desktop`,
 *      `mobile` and `slack` and nothing else, so no configuration of `Acquisitions_Deal_Update`
 *      produces one. Email would require `Messaging.SingleEmailMessage`.
 *   2. THIS CODEBASE HAS NO EMAIL PATH AT ALL. Verified 2026-08-31 across all 534 Apex classes:
 *      **zero** occurrences of `Messaging.SingleEmailMessage` and **zero** of `Messaging.sendEmail`.
 *      This feature would have been the first, which makes it an architectural decision rather than
 *      an implementation detail.
 *   3. THE ORG CANNOT BE SHOWN TO BE ABLE TO SEND. There are **zero `OrgWideEmailAddress` records**
 *      and the deliverability setting is unverified. `usman-dpeg` is a TRIAL EE org, and a trial org
 *      left on "System email only" swallows Apex-sent email — so the email half would have been
 *      SILENTLY DEAD while the deploy, the tests and the bell all looked healthy. That is precisely
 *      the failure mode this whole feature is built to avoid, and building it blind would have
 *      created the thing it exists to prevent.
 *
 * 🔴 THE OPEN DESIGN QUESTION A FUTURE IMPLEMENTER MUST ANSWER **BEFORE** WRITING ANY CODE, NOT
 * AFTER: **if the bell succeeds and the email fails, does the marker still stamp?** It is not a
 * detail; it is the same choice §2 below makes for a single channel, and with two channels there is
 * no answer that is merely "correct":
 *
 *   stamp anyway          the email is lost FOREVER and the marker claims the reminder went out.
 *   do not stamp          the BELL is re-sent every day until the email succeeds — reintroducing
 *                         the daily-spam failure the marker exists to prevent, on the channel that
 *                         was working.
 *   stamp per channel     needs a THIRD marker field, and turns `shouldFire` from one decision into
 *                         two. This is the only option that is actually correct, and it is a schema
 *                         change plus a rewrite of `StageDelayService.shouldFire` — which is why it
 *                         must be decided first.
 *
 * ⚠ Do NOT bolt an email onto `execute()` and leave the marker logic as it is. The current
 * send-then-stamp order is sound for ONE channel and is not defined for two.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 1. SCOPE = 200 — **INHERITED FROM `CallForOffersAlertBatch`, NOT RE-MEASURED**
 *    ...BUT THE RECIPIENT ARITHMETIC IS **RE-RUN HERE**, BECAUSE THIS JOB'S RECIPIENT SET IS
 *    NOT THE ONE THAT WAS MEASURED.
 * ═══════════════════════════════════════════════════════════════════════════
 * `CallForOffersAlertBatch`'s header §1 records five probes run against `usman-dpeg` on 2026-08-14
 * which established that `Messaging.CustomNotification.send()` has **no count ceiling at any scale
 * this kind of job can reach** (1,371 sends in one transaction, no exception), consumes zero SOQL
 * and zero DML, and costs:
 *
 *     one send()  ≈  6.0 ms CPU  +  0.22 ms x |recipients|
 *
 * 🔴 THE INHERITANCE IS LEGITIMATE BECAUSE THAT COST MODEL IS A PROPERTY OF THE NOTIFICATION API,
 * NOT OF THE OBJECT BEING ALERTED ON. Nothing in it mentions `NDA__c` or `Opportunity`; nothing
 * here would change it. Do NOT re-run the probes; DO cite them.
 *
 * ── 🔴 THE ARITHMETIC THAT IS *NOT* INHERITED, DONE HERE ────────────────────
 * The design brief flagged exactly this: *"If notifying the Owner needs a SECOND `send()` per deal,
 * re-run the CPU arithmetic for 400 sends/chunk before accepting SCOPE = 200."*
 *
 * **IT DOES NOT NEED A SECOND `send()`, AND THAT IS A DESIGN DECISION RATHER THAN AN OBSERVATION.**
 * `GroupNotifier.Request.additionalRecipientIds` (added 2026-08-31 for this job) merges the owner
 * into the SAME call's recipient set, so this job issues **ONE send per delayed deal**, exactly as
 * its two predecessors do. The arithmetic both ways, at the `Acquisition` queue's measured ONE
 * member (post-deploy gate P1 will grow it to team scale — tens):
 *
 *   SHAPE                          per deal            200 deals, worst case      share of 60,000 ms
 *   ────────────────────────────────────────────────────────────────────────────────────────────
 *   one send, R = 1 + owner = 2    6.0 + 0.44 = 6.44   1,288 ms                   ~2.1%   (47x margin)
 *   one send, R = 20 + owner = 21  6.0 + 4.62 = 10.62  2,124 ms                   ~3.5%   (28x margin)
 *   TWO sends (the rejected shape) 12.4                2,480 ms                   ~4.1%   (24x margin)
 *
 * ⇒ **SCOPE = 200 HOLDS EITHER WAY** — the two-send shape would also have been affordable, so this
 * is not a rescue, it is the cheaper of two workable options. It was taken because merging is 28x
 * cheaper per deal AND because a `Set` de-duplicates: an owner who is also a queue member gets ONE
 * notification, not two about the same deal.
 *
 * ⚠ THE TWO HONEST LIMITS OF THE INHERITED MEASUREMENT TRANSFER TOO: it establishes "no count
 * ceiling at or below 1,371" rather than "no count ceiling exists", and its recipient arms reach
 * only 10 real recipients (this org has 10 active users), so the 20/50-recipient figures are
 * extrapolated. Neither matters at SCOPE = 200. Recompute the table before pointing this job at a
 * group with hundreds of members.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 2. 🔴 SEND FIRST, STAMP SECOND. THE ORDER IS THE DESIGN, NOT AN ACCIDENT.
 * ═══════════════════════════════════════════════════════════════════════════
 * A notification is NOT transactional — once `send()` returns it is out, and no DML rollback
 * recalls it. The two orders fail in opposite directions and only one is recoverable:
 *
 *   stamp then send  a failed send leaves a marker claiming the reminder went out. The reminder is
 *                    lost FOREVER and nothing anywhere records it. SILENT.
 *   send then stamp  a failed stamp leaves the deal unmarked, so tomorrow's pass reminds again.
 *                    NOISY, VISIBLE, and self-correcting on the next successful stamp.
 *
 * This job takes the second, and it stamps ONLY the deals whose send actually succeeded — which is
 * why it calls `GroupNotifier.notifyWithOutcome` and **never** the swallow-everything `notify`.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 3. WHERE THE RULES LIVE — NOT HERE
 * ═══════════════════════════════════════════════════════════════════════════
 * Every threshold, and the whole suppression decision, live in `StageDelayService`
 * (`evaluate` / `shouldFire` / `locatorCeiling`), which is PURE. This class contributes no number
 * of its own. **If you find yourself writing `14` in this file, stop.**
 *
 * ⚠ THE WHOLE CHUNK IS EVALUATED AGAINST **ONE** `asOf`, captured once at the top of `execute`.
 * Calling `Date.today()` per record would let two deals in one chunk straddle midnight and produce
 * a run in which one is "day 13" and its neighbour is already "day 14".
 *
 * ⚠ THE LOCATOR'S CEILING IS ALSO COMPUTED FROM THE SERVICE, in `start()`. That is the one
 * structural improvement over the two predecessors, whose selectors carry a hardcoded `TODAY + N`
 * they have to apologise for: a `Database.QueryLocator` cannot bind an Apex COLLECTION, but it can
 * bind a single `Date`. See `OpportunitySelector.queryStalledDeals`.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 4. 🔴 SHARING — ASKED AS ITS OWN QUESTION, AND MEASURED. THE ANSWER IS "NOTHING TO DO".
 * ═══════════════════════════════════════════════════════════════════════════
 * `SYSTEM_MODE` lifts CRUD and FLS and **NEVER** sharing, so "the read and the write are
 * SYSTEM_MODE" is not an answer to the sharing question and was not treated as one.
 *
 * 🔴 THE BRIEF THAT COMMISSIONED THIS CLASS STATED "Opportunity OWD is Private". **IT IS NOT.**
 * Measured on `usman-dpeg` on 2026-08-31 via the Tooling API:
 * `EntityDefinition.InternalSharingModel = ReadWrite`, `ExternalSharingModel = Private` — the same
 * reading `OpportunitySelector.queryCallForOffersAlerts` took on 2026-08-14. Every internal user
 * already sees every Opportunity row, therefore:
 *
 *   THE READ   cannot be sharing-filtered into skipping deals owned by someone else. No
 *              `without sharing` inner class in the selector, and none is wanted.
 *   THE WRITE  cannot be refused for a non-owner. No `MarkerWrites` inner class, unlike
 *              `NdaExpiryAlertBatch` — `NDA__c` IS Private with no acquisition sharing rule, which
 *              is why that job needs two escapes and this one needs none.
 *
 * ⇒ This class is `with sharing`, matching `CallForOffersAlertBatch` (also `with sharing`, also
 * over Opportunity) rather than `NdaExpiryAlertBatch` (`without sharing`, over a Private object).
 * 🔴 DO NOT "MATCH THE NDA JOB" ON APPEARANCE. Its keyword is an argued response to a Private OWD
 * that does not exist here, and copying it would widen a boundary for no measured reason.
 *
 * 🔴 RESIDUAL, STATED BECAUSE IT IS THIS JOB'S SILENT-FAILURE MODE. OWD is ORG state, not repo
 * state, and standard-object OWD is UI-only so no file in this repo governs it. If `Opportunity` is
 * ever narrowed to Private, BOTH halves break at once and BOTH break silently: the locator returns
 * only the rows the scheduling principal owns, the marker write is refused as a `SaveResult` that
 * `allOrNone = false` swallows, `finish()` logs an all-zeros summary, and that is
 * INDISTINGUISHABLE FROM A HEALTHY PIPELINE. This repo has a recorded incident of exactly that
 * shape (`InboundEmailStagingSelector.RoutingReads`, 2026-08-08) and a recorded incident where a
 * swallowed sharing refusal INVERTED an idempotency guard into a duplicate-maker. The remedy THEN
 * is two narrow `private without sharing` inner classes — one per statement — not a keyword on
 * this class. Re-measure OWD if either symptom appears.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 5. GOVERNOR SHAPE
 * ═══════════════════════════════════════════════════════════════════════════
 * Per `execute()`: **0 SOQL of its own**, at most **1 DML statement**, and at most `SCOPE`
 * notifications — all CONSTANT in the number of deals in the chunk. `GroupNotifier` resolves the
 * queue's recipients at most once per transaction (it caches), so a 200-deal chunk pays the same 3
 * queries a 1-deal chunk does, and `Stage_Threshold_Def__mdt.getAll()` is a metadata accessor that
 * costs ZERO queries. A chunk in which nothing is owed a reminder costs **zero DML and zero
 * notifications**, which is what makes running this daily on a quiet pipeline free — and it is the
 * property the tests assert, rather than merely asserting that 251 rows produced 251 alerts.
 *
 * ⚠ `Database.Stateful` is carried ONLY for the summary counters. It holds no work state, so a
 * failed chunk loses nothing but its own numbers.
 *
 * ⚠ NOT `Database.AllowsCallouts` — `Messaging.CustomNotification.send()` is not an HTTP callout.
 *
 * ⚠ THE MARKER UPDATE RE-ENTERS `OpportunityReviewTrigger`, WHICH IS THE ONE COST THIS JOB HAS THAT
 * ITS TWO PREDECESSORS DO NOT — and it was checked rather than assumed. That trigger's before
 * contexts route `OpportunityStageEntryService`, which is ZERO SOQL / ZERO DML and, because this
 * update does not change `StageName`, does not even stamp (`priorStage == o.StageName` ⇒ `continue`).
 * Its after contexts branch on stage transitions and on `Contract_Signed__c`, none of which this
 * update touches. **The one unavoidable cost is `ensureNda()`**, which is idempotent — every deal
 * this job touches already has its NDA, having been open for at least the threshold — so it queries
 * and creates nothing. This is the reason the marker fields are written on their own minimal
 * `Opportunity(Id = ...)` shells: a fuller payload would invite a future reader to add a field the
 * trigger DOES branch on.
 *
 * ⚠ BULK TESTING: `.claude/rules/bulk-test-rule.md`'s 251-record mandate applies (this is a batch)
 * and is met, with **no exemption claimed**. Note what 251 proves here: a test method executes only
 * ONE chunk, so at `SCOPE = 200` a 251-row fixture proves the LOCATOR selects, filters and orders
 * 251 rows and that a full 200-row chunk behaves — it does not drive two `execute()` calls, and no
 * test can. `.claude/rules/content-publication-rule.md` does NOT apply: no `ContentVersion`,
 * `ContentNote` or `ContentDocument` is created anywhere in this feature.
 *
 * @see StageDelayService.cls                  (the thresholds, and `shouldFire` — the marker rule)
 * @see StageDelayAlertSchedule.cls            (🔴 the post-deploy scheduling gate)
 * @see OpportunitySelector.queryStalledDeals  (the work queue — SYSTEM_MODE, and the ceiling)
 * @see GroupNotifier.notifyWithOutcome        (why the outcome list exists)
 * @see GroupNotifier.Request.additionalRecipientIds (how the owner rides the same send)
 * @see NdaExpiryAlertBatch.cls                (the shape this follows, and the SCOPE it inherits)
 */
public with sharing class StageDelayAlertBatch implements Database.Batchable<SObject>, Database.Stateful {

    /**
     * Deals per transaction. 🔴 INHERITED from `CallForOffersAlertBatch.SCOPE`, deliberately not
     * re-measured — see the class header §1 for why that inheritance is legitimate, where the five
     * probes that justify it live, and for the recipient arithmetic that IS re-run here because
     * this job's recipient set (queue + owner) is not the one that was measured. It is NOT a
     * notification-count budget (no such ceiling was found at any reachable scale); it is a
     * blast-radius choice against a measured CPU cost of `6.0 ms + 0.22 ms x |recipients|` per
     * notification. 🔴 Quote the recipient count with the milliseconds — the bare figure is the
     * R = 1 case and reads as a constant when it is a function.
     */
    public static final Integer SCOPE = 200;

    /**
     * The alerting population — the `Acquisition` QUEUE, matching
     * `CallForOffersAlertBatch.RECIPIENT_GROUP` and `NdaExpiryAlertBatch.RECIPIENT_GROUP`
     * (recorded Gate 1 decision Q2.3, design finding F10). Three candidates exist in this org
     * (`queues/Acquisition`, `groups/Acquisitions_Team`, `groups/DPEG_Acquisitions_Team`); matching
     * the other two alert jobs is what stops the application's three alert jobs disagreeing about
     * who "the Acquisition team" is. ⚠ An earlier brief for this feature said "the Acquisitions
     * public group" — a FOURTH name, and it would have re-opened a settled question.
     *
     * ⚠ A queue is a valid custom-notification recipient — it can be told about a record it cannot
     * own. Confirming that this queue's MEMBERSHIP is the intended alerting population is
     * post-deploy gate P1; queue membership is not deployable metadata and no test can see it. It
     * was measured at ONE member. Until it is populated, `GroupNotifier` falls back to the queue's
     * own Id, which delivers to nobody useful — and because this job is send-then-stamp, that is
     * NOT silent-and-stamped, it re-evaluates every delayed deal every day. Noisy in the log, which
     * is the correct failure direction.
     *
     * ⚠ NOT `final`, and that is a TEST SEAM rather than an oversight: pointing it at a group that
     * does not exist is the only way to reproduce a swallowed send failure, which is the branch
     * that proves a failed reminder is NOT stamped — and that branch is the entire reason
     * `notifyWithOutcome` exists.
     */
    @TestVisible
    private static String RECIPIENT_GROUP = 'Acquisition';

    // ═══════════════════════════════════════════════════════════════════════
    // COUNTERS — TWO SETS, ON PURPOSE. THEY ANSWER DIFFERENT QUESTIONS.
    //
    // The `chunk*` STATICS are reset at the top of every `execute()` and describe THAT CHUNK. They
    // exist because a test CANNOT read the instance fields below: `Database.Stateful` serialises
    // the batch instance, so the object the test handed to `Database.executeBatch` is NOT the
    // object that ran and its fields never move. Statics captured INSIDE the async transaction are
    // this repo's established way round that (`ExtractAddressQueueable.lastRunQueryCount` is the
    // precedent) — and note the matching trap, which is why `chunkQueries` / `chunkDmlStatements`
    // measure a DELTA across this method's own body rather than being read from the test:
    // `Test.stopTest()` RESTORES the pre-test governor counters, so asserting `Limits.*` after it
    // is silently vacuous.
    //
    // The `total*` INSTANCE fields accumulate ACROSS chunks and are what `finish()` reports. A test
    // running a single chunk cannot see them; production, running many, needs them.
    // ═══════════════════════════════════════════════════════════════════════

    /** Deals the last `execute()` looked at. */
    @TestVisible
    private static Integer chunkEvaluated = 0;
    /** Deals the last `execute()` decided were owed a reminder. */
    @TestVisible
    private static Integer chunkOwed = 0;
    /** Notifications the last `execute()` actually sent. */
    @TestVisible
    private static Integer chunkNotified = 0;
    /** Requests `GroupNotifier` could not send — retried next pass, never stamped. */
    @TestVisible
    private static Integer chunkSendFailures = 0;
    /** Markers the last `execute()` wrote. Equals `chunkNotified` unless the stamp partly failed. */
    @TestVisible
    private static Integer chunkStamped = 0;
    /** DML statements this method's own body issued. Pins "at most 1, constant in chunk size". */
    @TestVisible
    private static Integer chunkDmlStatements = 0;
    /** SOQL queries this method's own body consumed. Pins "0 of its own". ⚠ It is NOT zero when a
     *  notification is actually sent — `GroupNotifier` spends up to 3 on its FIRST call in the
     *  transaction to resolve the queue and the notification type, then caches. The falsifiable
     *  claim is that the number does not GROW with the chunk size, and that a chunk owing nothing
     *  spends none at all. */
    @TestVisible
    private static Integer chunkQueries = 0;

    /** Cross-chunk totals for `finish()`; see the block comment above. */
    private Integer totalEvaluated = 0;
    private Integer totalOwed = 0;
    private Integer totalNotified = 0;
    private Integer totalSendFailures = 0;
    private Integer totalStamped = 0;
    /** Chunks whose work threw. The deals are untouched and stay in the queue. */
    private Integer failedChunks = 0;

    /** Zero the per-chunk statics. Called at the top of every `execute()`. */
    @TestVisible
    private static void resetChunkCounters() {
        chunkEvaluated = 0;
        chunkOwed = 0;
        chunkNotified = 0;
        chunkSendFailures = 0;
        chunkStamped = 0;
        chunkDmlStatements = 0;
        chunkQueries = 0;
    }

    /**
     * The work queue: open, anchored deals at or past the widest configured threshold.
     *
     * ⚠ THE CEILING COMES FROM THE SERVICE, NOT FROM A LITERAL HERE. See the class header §3.
     *
     * @param ctx The batch context (unused; required by the interface).
     * @return A locator over candidate deals, longest-stalled first.
     */
    public Database.QueryLocator start(Database.BatchableContext ctx) {
        return OpportunitySelector.queryStalledDeals(
            StageDelayService.locatorCeiling(Date.today())
        );
    }

    /**
     * Remind on one chunk. See the class header §2 for why the order is send-then-stamp.
     *
     * FAIL-SOFT PER CHUNK: a batch has NO Finalizer, so a failure here is recorded here or nowhere.
     * The deals in a failed chunk are untouched, so they stay in the locator and are retried on the
     * next pass; the catch exists so one bad chunk cannot abort the remaining ones.
     *
     * @param ctx   The batch context (unused).
     * @param scope The deals to consider; at most `SCOPE`.
     */
    public void execute(Database.BatchableContext ctx, List<Opportunity> scope) {
        resetChunkCounters();
        if (scope == null || scope.isEmpty()) {
            return;
        }
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        try {
            // ONE clock for the whole chunk — see the class header §3.
            Date asOf = Date.today();

            List<GroupNotifier.Request> requests = new List<GroupNotifier.Request>();
            // Index-aligned with `requests`: the marker each successful send earns.
            List<Opportunity> pendingStamps = new List<Opportunity>();

            for (Opportunity opp : scope) {
                if (opp == null || opp.Id == null) {
                    continue;
                }
                chunkEvaluated++;
                StageDelayService.StageDelay state = StageDelayService.evaluate(
                    opp.StageName, opp.Stage_Entry_Date__c, asOf
                );
                if (!StageDelayService.shouldFire(
                        state.isDelayed,
                        opp.StageName,
                        opp.Stage_Entry_Date__c,
                        opp.Stage_Alert_Stage__c,
                        opp.Stage_Alert_Last_Sent_Date__c)) {
                    continue;
                }
                chunkOwed++;
                requests.add(buildRequest(opp, state));
                pendingStamps.add(new Opportunity(
                    Id = opp.Id,
                    Stage_Alert_Last_Sent_Date__c = asOf,
                    // 🔴 THE SNAPSHOT — see StageDelayService §3. Storing the stage the reminder was
                    // ABOUT is what lets a later stage change re-arm the reminder by itself, with no
                    // writer of `StageName` needing to know this feature exists. A date-only marker
                    // would leave a deal that moved on and stalled again permanently silent.
                    Stage_Alert_Stage__c = opp.StageName
                ));
            }

            if (requests.isEmpty()) {
                accumulate();
                return;
            }

            List<Boolean> outcomes = GroupNotifier.notifyWithOutcome(requests);
            List<Opportunity> toStamp = new List<Opportunity>();
            for (Integer i = 0; i < pendingStamps.size(); i++) {
                Boolean sent = (i < outcomes.size()) && outcomes[i] == true;
                if (sent) {
                    chunkNotified++;
                    toStamp.add(pendingStamps[i]);
                } else {
                    chunkSendFailures++;
                }
            }
            if (!toStamp.isEmpty()) {
                stampMarkers(toStamp);
            }
            accumulate();
        } catch (Exception e) {
            failedChunks++;
            accumulate();
            System.debug(LoggingLevel.ERROR,
                'StageDelayAlertBatch: chunk of ' + scope.size() + ' failed: '
                + e.getTypeName() + ' | ' + e.getMessage()
                + ' | the deals are untouched and stay in the queue for the next pass.');
        } finally {
            // In a finally so an unexpected throw cannot leave the governor counters reading zero
            // and make a budget assertion pass for the wrong reason.
            chunkQueries = Limits.getQueries() - queriesBefore;
            chunkDmlStatements = Limits.getDmlStatements() - dmlBefore;
        }
    }

    /** Roll this chunk's statics into the cross-chunk totals `finish()` reports. */
    private void accumulate() {
        totalEvaluated += chunkEvaluated;
        totalOwed += chunkOwed;
        totalNotified += chunkNotified;
        totalSendFailures += chunkSendFailures;
        totalStamped += chunkStamped;
    }

    /**
     * Write the reminder markers for the deals that were actually notified.
     *
     * 🔴 TWO DECISIONS, AND A THIRD THAT WAS CONSIDERED AND REJECTED ON EVIDENCE:
     *
     *  1. `AccessLevel.SYSTEM_MODE` — both marker fields are Metadata-API-deployed customs, which
     *     arrive with NO field permissions for ANY profile, System Administrator included, so a
     *     user-mode write would refuse on day one for the very administrator who deployed them,
     *     with `fields being inaccessible`. No principal asked for this write; the scheduler makes
     *     it on the team's behalf. ⚠ Note this is a CALLER-BUILT DML PAYLOAD, which is precisely
     *     the construct that raises that error — unlike a before-trigger in-memory assignment
     *     (`OpportunityStageEntryService`), which needs no grant at all.
     *  2. `allOrNone = false` — one refused row must not cost the other 199 their markers, because
     *     a notified-but-unstamped deal reminds AGAIN tomorrow. Partial success is strictly better.
     *  3. 🔴 **REJECTED: a `private without sharing` inner class**, which is what
     *     `NdaExpiryAlertBatch.MarkerWrites` does. It is NOT needed here and adding it would widen
     *     a boundary for no reason: `NDA__c` is Private OWD with no acquisition sharing rule, so
     *     that job's non-owner update is genuinely refused; `Opportunity` internal OWD is
     *     **ReadWrite** (measured 2026-08-31, Tooling API), so this one is not. See the class
     *     header §4 — including what to do if that ever changes.
     *
     * @param toStamp Marker-only Opportunity shells; never empty when called.
     */
    private void stampMarkers(List<Opportunity> toStamp) {
        List<Database.SaveResult> results =
            Database.update(toStamp, false, AccessLevel.SYSTEM_MODE);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                chunkStamped++;
                continue;
            }
            // A lost marker is NOISY, not silent — the deal re-reminds next pass. Recorded so the
            // cause is findable, because the symptom (a repeating reminder) points somewhere else.
            String detail = results[i].getErrors().isEmpty()
                ? 'no error detail'
                : results[i].getErrors()[0].getStatusCode() + ': ' + results[i].getErrors()[0].getMessage();
            System.debug(LoggingLevel.WARN,
                'StageDelayAlertBatch: reminder SENT but marker NOT stamped for '
                + toStamp[i].Id + ' (' + detail + '). This deal will remind again on the next pass.');
        }
    }

    /**
     * The notification for one deal. Every string comes from the shared service, so a future badge
     * and the bell cannot describe the same stall two different ways.
     *
     * 🔴 THE OWNER RIDES THIS SAME REQUEST rather than getting a second one — see the class header
     * §1 for the arithmetic and `GroupNotifier.Request.additionalRecipientIds` for the mechanism.
     * `OwnerId` is a standard field on a standard object and needs no FLS grant, which is why the
     * owner half of the recipient decision carries none of the day-one risk the marker fields do.
     *
     * ⚠ THERE IS DELIBERATELY NO "IS THE OWNER A USER?" TEST, AND THAT WAS MEASURED RATHER THAN
     * ASSUMED. The concern is real in general: `Messaging.CustomNotification.send()` REJECTS THE
     * WHOLE CALL on one unusable recipient (probed 2026-08-31 — `System.HandledException: Invalid
     * parameter value for: recipientIds`, nothing delivered), so a queue-owned deal would silence
     * its own reminder to the queue as well. A `005` prefix guard was written for exactly that and
     * then **removed as dead code**: `Opportunity` is not a queue-ownable object in this org, and
     * an `OwnerId` set to a `00G` Id is REFUSED at the platform level with
     * `FIELD_INTEGRITY_EXCEPTION: Owner ID: id value of incorrect type` (probed the same day,
     * against `usman-dpeg`). A guard whose false branch cannot be reached is not defensive, it is
     * an untestable line that misleads the next reader about what shapes this field can hold.
     * 🔴 IF THIS EVER MOVES TO A QUEUE-OWNABLE OBJECT (`Lead`, `Case`, `Order`, or any custom
     * object), THE GUARD MUST COME BACK — the rejection is all-or-nothing per call, not per
     * recipient.
     *
     * @param opp   The deal being reminded on.
     * @param state Its computed stall state.
     * @return The notification request.
     */
    private GroupNotifier.Request buildRequest(Opportunity opp, StageDelayService.StageDelay state) {
        GroupNotifier.Request request = new GroupNotifier.Request();
        request.recipientGroup = RECIPIENT_GROUP;
        request.targetRecordId = opp.Id;
        request.title = 'Deal delayed — ' + state.label;
        request.body = opp.Name + ' — ' + state.detail;
        if (opp.OwnerId != null) {
            request.additionalRecipientIds = new Set<String>{ String.valueOf(opp.OwnerId) };
        }
        return request;
    }

    /**
     * Summarise the pass. Deliberately a debug line and nothing more: the durable record of what
     * was reminded lives on each deal's own two marker fields, which are queryable and reportable —
     * unlike a static or a log line.
     *
     * ⚠ IT ALSO NAMES THE THRESHOLD ROW COUNT, and that is the point of the extra clause. The rows
     * are script-loaded, not deployed (post-deploy step P3), so "the loader was never run" is a
     * real and likely state. `StageDelayService` falls back to a flat 14-day threshold and warns,
     * so the feature is not dead — but the fallback is invisible unless something says so, and this
     * is the line an operator reads.
     *
     * @param ctx The batch context (unused).
     */
    public void finish(Database.BatchableContext ctx) {
        System.debug(LoggingLevel.INFO,
            'StageDelayAlertBatch finished: evaluated=' + totalEvaluated
            + ' owed=' + totalOwed
            + ' notified=' + totalNotified
            + ' stamped=' + totalStamped
            + ' sendFailures=' + totalSendFailures
            + ' failedChunks=' + failedChunks
            + ' | Stage_Threshold_Def__mdt rows in org=' + Stage_Threshold_Def__mdt.getAll().size()
            + ' (0 means scripts/load-stage-threshold-defs.apex has NOT been run and the shipped '
            + 'fallback threshold is in force).');
    }
}
