/**
 * The daily NDA expiry reminder. Notifies the `Acquisition` queue 5 days and 2 days before a signed
 * acquisition NDA's `NDA_Expiry_Date__c`, exactly once per rung per expiry date.
 * FSD Tranche 1, Item 2 (FSD §15.2).
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 1. SCOPE = 200 — **INHERITED FROM `CallForOffersAlertBatch`, NOT RE-MEASURED**
 * ═══════════════════════════════════════════════════════════════════════════
 * State that plainly rather than implying a fresh measurement. `CallForOffersAlertBatch`'s header
 * §1 records five probes run against `usman-dpeg` on 2026-08-14 which established that
 * `Messaging.CustomNotification.send()` has **no count ceiling at any scale this kind of job can
 * reach** (1,371 sends in one transaction, no exception), consumes zero SOQL and zero DML, and
 * costs:
 *
 *     one send()  ≈  6.0 ms CPU  +  0.22 ms x |recipients|
 *
 * 🔴 THE INHERITANCE IS LEGITIMATE BECAUSE THAT COST MODEL IS A PROPERTY OF THE NOTIFICATION API,
 * NOT OF THE OBJECT BEING ALERTED ON. Nothing in it mentions `Opportunity`; nothing here would
 * change it. This job sends at most one notification per NDA per rung against the same 60,000 ms
 * async CPU budget, so at 200 rows and the `Acquisition` queue's measured ONE member the worst case
 * is ~1,240 ms — about 2.1% of budget, a 48x margin. Do NOT re-run the probes; DO cite them.
 *
 * ⚠ THE TWO HONEST LIMITS OF THE INHERITED MEASUREMENT TRANSFER TOO: it establishes "no count
 * ceiling at or below 1,371" rather than "no count ceiling exists", and its recipient arms reach
 * only 10 real recipients (this org has 10 active users), so the 20/50-recipient figures are
 * extrapolated. Neither matters at SCOPE = 200. Recompute that table before pointing this job at a
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
 *   send then stamp  a failed stamp leaves the NDA unmarked, so tomorrow's pass reminds again.
 *                    NOISY, VISIBLE, and self-correcting on the next successful stamp.
 *
 * This job takes the second, and it stamps ONLY the NDAs whose send actually succeeded — which is
 * why it calls `GroupNotifier.notifyWithOutcome` rather than the swallow-everything `notify`.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 3. WHERE THE RULES LIVE — NOT HERE
 * ═══════════════════════════════════════════════════════════════════════════
 * Both thresholds and the whole idempotency decision live in `NdaExpiryService` (`evaluate` /
 * `shouldFire`), which is PURE. This class contributes no ladder of its own. **If you find yourself
 * writing `5` or `2` in this file, stop.**
 *
 * ⚠ THE WHOLE CHUNK IS EVALUATED AGAINST **ONE** `asOf`, captured once at the top of `execute`.
 * Calling `Date.today()` per record would let two NDAs in one chunk straddle midnight and produce a
 * run in which one is "expires today" and its neighbour is already "expired".
 *
 * ⚠ `NDA_Alert_Last_Interval__c` IS `Number(2,0)`, SO IT ARRIVES AS A **`Decimal`**, not an
 * `Integer` — it is cast with `.intValue()` before it reaches `shouldFire`. Same trap, same cast,
 * as `CallForOffersAlertBatch` and `InboundEmailStagingService.markRoutingFailed`.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 4. 🔴 SHARING — TWO SEPARATE HOLES, TWO SEPARATE FIXES, NEITHER COVERING THE OTHER
 * ═══════════════════════════════════════════════════════════════════════════
 * `NDA__c` is `sharingModel = Private`, and its only two sharing rules are criteria-scoped to
 * `RecordTypeId = 'Disposition NDA'` — **nothing shares an acquisition NDA to anyone**. So:
 *
 *   THE READ   fixed in `NdaSelector.ExpiryAlertReads` (`private without sharing`). Without it the
 *              locator returns only the rows the SCHEDULING user owns, `finish()` logs an
 *              all-zeros summary, and that is indistinguishable from a healthy job.
 *   THE WRITE  fixed in `MarkerWrites` below (`private without sharing`). `SYSTEM_MODE` lifts CRUD
 *              and FLS and **NEVER** sharing, so a Private-OWD `update` by a non-owner is REFUSED.
 *              And the refusal is INVISIBLE — `allOrNone = false` turns it into a `SaveResult`, so
 *              the job would re-remind the same NDA **every single day, forever**, which is
 *              precisely the failure the marker exists to prevent.
 *
 * 🔴 Do not "simplify" either one away on the strength of the other: the escape belongs to the two
 * statements that need it, and a keyword on this class does not reach either of them.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 4b. 🔴 WHY THIS CLASS IS `without sharing` — REQUIRED JUSTIFICATION (ARCHITECTURE.md §2
 *     Standards: `without sharing` needs written justification in the class header).
 *     ⚠ AMENDED 2026-08-16 (code review W2). §4 above ENDED with "do not put `without sharing` on
 *     this class instead" — that clause was DELETED, not softened, and the sentence it sat in now
 *     makes the narrower point it was always really making. Do not restore it from git history.
 * ═══════════════════════════════════════════════════════════════════════════
 * THE KEYWORD IS NOT A REPLACEMENT FOR EITHER FIX IN §4 AND DOES NOT WEAKEN THEM. It exists to
 * remove an UNKNOWN that `NdaSelector.ExpiryAlertReads`' header used to carry and hand to
 * post-deploy gate G2:
 *
 *   Whether the platform re-applies the BATCH CLASS's sharing context when it chunks a
 *   `Database.QueryLocator` that was built inside a `without sharing` inner class is
 *   NOT ESTABLISHED BY ANY FILE IN THIS REPO. All three in-repo precedents
 *   (`InboundEmailStagingSelector.RoutingReads`, `PropertyAssetSelector.AssetCreationReads`,
 *   `PropertySelector.FolderCreationReads`) leave their batch/caller `with sharing`, so none of
 *   them answers it either.
 *
 * WHY REMOVING IT COSTS NOTHING — THE ARGUMENT, NOT AN ASSERTION. `without sharing` on a class
 * governs (a) that class's OWN SOQL and DML and (b) any callee that declares NO sharing keyword of
 * its own. This class has NEITHER exposure, and each half was checked rather than assumed:
 *   (a) IT CONTAINS ZERO SOQL AND ZERO DIRECT DML. `start` delegates to
 *       `NdaSelector.queryExpiryAlerts`; the only `Database.update` in the file is inside
 *       `MarkerWrites`, which is ALREADY `private without sharing` and argues its own case.
 *   (b) EVERY CALLEE DECLARES ITS OWN KEYWORD, so none of them inherits this one:
 *       `NdaSelector` is `public with sharing` (and its one escaping read is its own inner class),
 *       `NdaExpiryService` is `public with sharing` AND holds zero SOQL/DML, and `GroupNotifier` is
 *       ALREADY `public without sharing`. There is no third-party callee to widen.
 * ⇒ The keyword widens NOTHING that is not already deliberately widened, and it closes the ONLY
 *   path by which the escape in §4 could be silently re-applied out from under this job.
 *
 * WHY IT IS WORTH DOING AT ALL, GIVEN IT MAY BE A NO-OP: because the consequence of the unknown
 * resolving the wrong way is the failure this class names TWICE in its own header — a locator that
 * returns only the rows the SCHEDULING principal owns, an all-zeros `finish()` summary, and a job
 * that is INDISTINGUISHABLE FROM A HEALTHY ONE. A free removal of a silent-failure mode beats a
 * watched one.
 *
 * 🔴 POST-DEPLOY GATE G2 IS RETAINED, NOT CLOSED BY THIS. This keyword is an argument, not a
 * measurement: nothing here proves the sharing context of a chunked locator, it only removes the
 * one mechanism this repo could identify. G2 still stands — confirm AS THE SCHEDULING PRINCIPAL
 * that a real pass selects AND stamps an acquisition NDA that principal does not own. Anyone who
 * reads this block as "G2 is handled" has misread it.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 5. GOVERNOR SHAPE
 * ═══════════════════════════════════════════════════════════════════════════
 * Per `execute()`: **0 SOQL of its own**, at most **1 DML statement**, and at most `SCOPE`
 * notifications — all CONSTANT in the number of NDAs in the chunk. `GroupNotifier` resolves the
 * queue's recipients at most once per transaction (it caches), so a 200-NDA chunk pays the same 3
 * queries a 1-NDA chunk does. A chunk in which nothing is owed a reminder costs **zero DML and zero
 * notifications**, which is what makes running this daily on a quiet pipeline free.
 *
 * ⚠ `Database.Stateful` is carried ONLY for the summary counters. It holds no work state, so a
 * failed chunk loses nothing but its own numbers.
 *
 * ⚠ NOT `Database.AllowsCallouts` — `Messaging.CustomNotification.send()` is not an HTTP callout.
 *
 * ⚠ THE MARKER UPDATE RE-FIRES THE TWO `NDA__c` FLOWS, AND BOTH WERE CHECKED RATHER THAN ASSUMED.
 * `NDA_Signed_Status_Sync` is BEFORE-SAVE and does no DML. `NDA_Signed_Rollup` is after-save but its
 * entry condition is **`Disposition__c IS NOT NULL`** (read off the flow file 2026-08-16), and every
 * row this job touches has `Opportunity__c != NULL` and therefore a null `Disposition__c` — so it
 * never runs for an acquisition NDA. `NDA__c` has no trigger and no validation rules, so there is
 * no recursion apparatus to add and none is added.
 *
 * ⚠ RECIPIENTS MUST BE ABLE TO OPEN THE TARGET. `targetRecordId` is the `NDA__c` Id, and `NDA__c` is
 * Private OWD with no acquisition sharing rule — so a notification is deliverable to someone who
 * cannot open the record it points at. Acquisitions personas hold `viewAllRecords` on `NDA__c`
 * today, so this is fine; it is recorded because it is a property of the queue's MEMBERSHIP
 * (post-deploy gate G3), which no test can see.
 *
 * ⚠ BULK TESTING: `.claude/rules/bulk-test-rule.md`'s 251-record mandate applies (this is a batch)
 * and is met, with no exemption claimed. Note what 251 proves here: a test method executes only ONE
 * chunk, so at SCOPE = 200 a 251-row fixture proves the LOCATOR selects, filters and orders 251
 * rows and that a full 200-row chunk behaves — it does not drive two `execute()` calls, and no test
 * can.
 *
 * @see NdaExpiryService.cls               (both thresholds, and `shouldFire` — the marker rule)
 * @see NdaExpiryAlertSchedule.cls         (🔴 the post-deploy scheduling gate)
 * @see NdaSelector.queryExpiryAlerts      (the work queue — SYSTEM_MODE, without sharing, and the
 *                                          Opportunity__c discriminator)
 * @see GroupNotifier.notifyWithOutcome    (why the outcome list exists)
 * @see CallForOffersAlertBatch.cls        (the shape this follows, and the SCOPE it inherits)
 */
public without sharing class NdaExpiryAlertBatch implements Database.Batchable<SObject>, Database.Stateful {

    /**
     * NDAs per transaction. 🔴 INHERITED from `CallForOffersAlertBatch.SCOPE`, deliberately not
     * re-measured — see the class header §1 for why that inheritance is legitimate and where the
     * five probes that justify it live. It is NOT a notification-count budget (no such ceiling was
     * found at any reachable scale); it is a blast-radius choice against a measured CPU cost of
     * `6.0 ms + 0.22 ms x |recipients|` per notification. 🔴 Quote the recipient count with the
     * milliseconds — the bare figure is the R = 1 case and reads as a constant when it is a
     * function.
     */
    public static final Integer SCOPE = 200;

    /**
     * The alerting population — the `Acquisition` QUEUE, matching
     * `CallForOffersAlertBatch.RECIPIENT_GROUP` (Gate 1 decision Q2.3). Three candidates existed
     * (`Acquisition` queue, `Acquisitions_Team` group, `DPEG_Acquisitions_Team` group); matching the
     * only other alert job in the application is what stops the two disagreeing about who "the
     * Acquisition team" is.
     *
     * ⚠ A queue is a valid custom-notification recipient — it can be told about a record it cannot
     * own. Confirming that this queue's MEMBERSHIP is the intended alerting population is
     * post-deploy gate G3; queue membership is not deployable metadata and no test can see it. It
     * was measured at ONE member.
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
    // precedent) — and note the matching trap: `Test.stopTest()` RESTORES the pre-test governor
    // counters, so asserting `Limits.*` after it is silently vacuous.
    //
    // The `total*` INSTANCE fields accumulate ACROSS chunks and are what `finish()` reports. A test
    // running a single chunk cannot see them; production, running many, needs them.
    // ═══════════════════════════════════════════════════════════════════════

    /** NDAs the last `execute()` looked at. */
    @TestVisible
    private static Integer chunkEvaluated = 0;
    /** NDAs the last `execute()` decided were owed a reminder. */
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
    /** DML statements the last `execute()` issued. Pins the "at most 1, constant in chunk size" claim. */
    @TestVisible
    private static Integer chunkDmlStatements = 0;

    /** Cross-chunk totals for `finish()`; see the block comment above. */
    private Integer totalEvaluated = 0;
    private Integer totalOwed = 0;
    private Integer totalNotified = 0;
    private Integer totalSendFailures = 0;
    private Integer totalStamped = 0;
    /** Chunks whose work threw. The NDAs are untouched and stay in the queue. */
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
    }

    /**
     * The work queue: signed acquisition NDAs whose expiry is inside the reminder ladder.
     *
     * @param ctx The batch context (unused; required by the interface).
     * @return A locator over candidate NDAs, soonest expiry first.
     */
    public Database.QueryLocator start(Database.BatchableContext ctx) {
        return NdaSelector.queryExpiryAlerts();
    }

    /**
     * Remind on one chunk. See the class header §2 for why the order is send-then-stamp.
     *
     * FAIL-SOFT PER CHUNK: a batch has NO Finalizer, so a failure here is recorded here or nowhere.
     * The NDAs in a failed chunk are untouched, so they stay in the locator and are retried on the
     * next pass; the catch exists so one bad chunk cannot abort the remaining ones.
     *
     * @param ctx   The batch context (unused).
     * @param scope The NDAs to consider; at most `SCOPE`.
     */
    public void execute(Database.BatchableContext ctx, List<NDA__c> scope) {
        resetChunkCounters();
        if (scope == null || scope.isEmpty()) {
            return;
        }
        try {
            // ONE clock for the whole chunk — see the class header §3.
            Date asOf = Date.today();

            List<GroupNotifier.Request> requests = new List<GroupNotifier.Request>();
            // Index-aligned with `requests`: the marker each successful send earns.
            List<NDA__c> pendingStamps = new List<NDA__c>();

            for (NDA__c nda : scope) {
                if (nda == null || nda.Id == null) {
                    continue;
                }
                chunkEvaluated++;
                NdaExpiryService.NdaExpiry state =
                    NdaExpiryService.evaluate(nda.NDA_Expiry_Date__c, asOf);

                // Number -> Integer: the field is Number(2,0), so it arrives as a Decimal.
                Integer lastInterval = (nda.NDA_Alert_Last_Interval__c == null)
                    ? null
                    : nda.NDA_Alert_Last_Interval__c.intValue();

                if (!NdaExpiryService.shouldFire(
                        state.dueInterval, lastInterval,
                        nda.NDA_Expiry_Date__c, nda.NDA_Alert_Expiry_Date__c)) {
                    continue;
                }
                chunkOwed++;
                requests.add(buildRequest(nda, state));
                pendingStamps.add(new NDA__c(
                    Id = nda.Id,
                    NDA_Alert_Last_Interval__c = state.dueInterval,
                    // The SNAPSHOT — see NdaExpiryService §3. Storing the LIVE expiry is what lets a
                    // later change to it re-arm the whole ladder by itself, with no writer of the
                    // expiry date needing to know this feature exists.
                    NDA_Alert_Expiry_Date__c = nda.NDA_Expiry_Date__c
                ));
            }

            if (requests.isEmpty()) {
                accumulate();
                return;
            }

            List<Boolean> outcomes = GroupNotifier.notifyWithOutcome(requests);
            List<NDA__c> toStamp = new List<NDA__c>();
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
                'NdaExpiryAlertBatch: chunk of ' + scope.size() + ' failed: '
                + e.getTypeName() + ' | ' + e.getMessage()
                + ' | the NDAs are untouched and stay in the queue for the next pass.');
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
     * Write the reminder markers for the NDAs that were actually notified.
     *
     * 🔴 THREE DECISIONS, NONE IMPLIED BY THE OTHERS:
     *
     *  1. `AccessLevel.SYSTEM_MODE` — both marker fields are Metadata-API-deployed customs, which
     *     arrive with NO field permissions for ANY profile, System Administrator included, so a
     *     user-mode write would refuse on day one for the very administrator who deployed them. No
     *     principal asked for this write; the scheduler makes it on the team's behalf.
     *  2. `allOrNone = false` — one refused row must not cost the other 199 their markers, because
     *     an unstamped-but-notified NDA reminds AGAIN tomorrow. Partial success is strictly better.
     *  3. 🔴 **`without sharing`, via `MarkerWrites`** — and this one is NOT covered by (1).
     *     `SYSTEM_MODE` lifts CRUD and FLS and NEVER sharing; `NDA__c` is Private OWD with no
     *     acquisition sharing rule, so an `update` by a principal who does not own the row is
     *     REFUSED. Combined with (2) that refusal is SILENT — a `SaveResult`, not an exception —
     *     and the job would re-remind the same NDA every single day forever. Class header §4.
     *
     * @param toStamp Marker-only NDA shells; never empty when called.
     */
    private void stampMarkers(List<NDA__c> toStamp) {
        chunkDmlStatements++;
        List<Database.SaveResult> results = new MarkerWrites().stampMarkers(toStamp);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                chunkStamped++;
                continue;
            }
            // A lost marker is NOISY, not silent — the NDA re-reminds next pass. Recorded so the
            // cause is findable, because the symptom (a repeating reminder) points somewhere else.
            String detail = results[i].getErrors().isEmpty()
                ? 'no error detail'
                : results[i].getErrors()[0].getStatusCode() + ': ' + results[i].getErrors()[0].getMessage();
            System.debug(LoggingLevel.WARN,
                'NdaExpiryAlertBatch: reminder SENT but marker NOT stamped for '
                + toStamp[i].Id + ' (' + detail + '). This NDA will remind again on the next pass.');
        }
    }

    /**
     * 🔴 THE MARKER WRITE, WHICH MUST RUN **WITHOUT SHARING**.
     *
     * The mirror of `InboundEmailStagingService.RoutingWrites`, and it exists for the identical
     * reason: the object is `sharingModel = Private`, the rows are owned by whoever created the
     * NDA rather than by the scheduling principal, and the caller is FAIL-SOFT — so a sharing
     * refusal would be swallowed as a `SaveResult` and the job would re-remind the same NDA every
     * day, forever, with no error anywhere.
     *
     * It holds ONLY this update, and it is STILL REQUIRED even though the enclosing class became
     * `without sharing` on 2026-08-16 (code review W2, class header §4b).
     *
     * 🔴 THE TWO ARE NOT REDUNDANT AND ONE MUST NOT BE DELETED ON THE STRENGTH OF THE OTHER.
     * ⚠ This paragraph replaced "The enclosing class stays `with sharing`; do not promote the
     * keyword outward" — the observation was true when written and is not a rule to restore.
     * The outer keyword exists to remove an UNKNOWN about the sharing context of a chunked
     * `QueryLocator` (an argument, not a measurement); this inner class is the DELIBERATE,
     * ARGUED escape for the write, and it is what a reader finds when they ask why this DML
     * escapes sharing. Deleting it would make the write's escape an accidental side effect of a
     * keyword three hundred lines away that was added for a different reason — and it would
     * silently re-open the failure in §4 the moment anyone narrowed the outer class back.
     */
    private without sharing class MarkerWrites {

        /**
         * Commit the marker stamps, without sharing.
         *
         * @param toStamp Marker-only `NDA__c` shells carrying an Id and the two marker fields; the
         *                caller owns every decision about what is in the list.
         * @return One `Database.SaveResult` per row, in input order.
         */
        private List<Database.SaveResult> stampMarkers(List<NDA__c> toStamp) {
            return Database.update(toStamp, false, AccessLevel.SYSTEM_MODE);
        }
    }

    /**
     * The notification for one NDA. Every string comes from the shared service, so a future badge
     * and the bell cannot describe the same expiry two different ways.
     *
     * @param nda   The NDA being reminded on.
     * @param state Its computed expiry state.
     * @return The notification request.
     */
    private GroupNotifier.Request buildRequest(NDA__c nda, NdaExpiryService.NdaExpiry state) {
        GroupNotifier.Request request = new GroupNotifier.Request();
        request.recipientGroup = RECIPIENT_GROUP;
        // ⚠ The NDA itself, not its Opportunity — the action a reader must take (renew, extend or
        // let lapse) is on this record. See the class header's note on recipient visibility.
        request.targetRecordId = nda.Id;
        request.title = 'NDA ' + state.label;
        String counterparty = String.isBlank(nda.Counterparty_Name__c)
            ? ''
            : ' Counterparty: ' + nda.Counterparty_Name__c + '.';
        request.body = nda.Name + ' — ' + state.detail + counterparty;
        return request;
    }

    /**
     * Summarise the pass. Deliberately a debug line and nothing more: the durable record of what
     * was reminded lives on each NDA's own two marker fields, which are queryable and reportable —
     * unlike a static or a log line.
     *
     * @param ctx The batch context (unused).
     */
    public void finish(Database.BatchableContext ctx) {
        System.debug(LoggingLevel.INFO,
            'NdaExpiryAlertBatch finished: evaluated=' + totalEvaluated
            + ' owed=' + totalOwed
            + ' notified=' + totalNotified
            + ' stamped=' + totalStamped
            + ' sendFailures=' + totalSendFailures
            + ' failedChunks=' + failedChunks);
    }
}
