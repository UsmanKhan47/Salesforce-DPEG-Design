/**
 * The daily call-for-offers deadline alert. Notifies the `Acquisition` queue at 7, 3 and 1 days
 * before a deal's `Offer_Due_Date__c` and on the day itself, exactly once per rung per deadline.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 1. 🔴 SCOPE = 200, AND IT IS **NOT** A NOTIFICATION BUDGET — THE MEASUREMENT SAYS SO
 * ═══════════════════════════════════════════════════════════════════════════
 * The brief instructed that `SCOPE` be derived from this org's per-transaction
 * `Messaging.CustomNotification.send()` ceiling, MEASURED before being fixed, and explicitly
 * warned against copying `DealFolderSweepBatch`'s `SCOPE = 10` (a CALLOUT budget, unrelated).
 * It was measured. **THE ANSWER IS THAT NO SUCH COUNT CEILING EXISTS AT ANY SCALE THIS JOB CAN
 * REACH**, so the instruction's premise does not hold and `SCOPE` is derived from what actually
 * binds instead. Both probes ran against `usman-dpeg` on 2026-08-14 as
 * `usman.khan.dpeg@avanzasolutions.com`, sending real notifications to the running user:
 *
 *   PROBE 1  300 sequential send() calls in ONE transaction, |recipients| = 1
 *            -> sentOk=300, err=NONE, CPU 2,162 / 10,000 ms, DML 0/150, SOQL 2/100
 *   PROBE 2  send() in a loop guarded only on CPU (stop at 8,500 ms), |recipients| = 1
 *            -> sentOk=1,371, err=NONE, CPU 8,501 ms
 *
 * 🔴 **BOTH PROBES RAN WITH A RECIPIENT SET OF EXACTLY ONE — THE RUNNING USER.** State that
 * denominator whenever the 6.20 ms figure is quoted. An earlier version of this header omitted it,
 * which let "6.20 ms per send" read as a CONSTANT when it is a FUNCTION of the recipient count, and
 * this job's live recipient set is a QUEUE whose membership is expected to grow (post-deploy gate
 * G2). The scaling was therefore measured too; see the next block.
 *
 * ⇒ **1,371 sends in one transaction with NO exception of any kind.** There is no
 * `LimitException`, no count cap, and `Messaging.CustomNotification.send()` consumes **zero SOQL
 * and zero DML**. What it consumes is CPU, at a measured **6.20 ms per send to one recipient**
 * (8,501 / 1,371). `System.Limits` exposes no counter for it and the org `/limits` REST resource
 * lists no notification entry (checked: 71 limit rows, zero matching `/notif|custom/i`), so CPU is
 * not merely the first thing to bind — it is the only observable cost.
 *
 * ── 🔴 HOW THE COST SCALES WITH RECIPIENT COUNT (MEASURED 2026-08-14) ────────
 * `GroupNotifier` passes the WHOLE resolved member set to one `send()` call, and the platform
 * materialises one notification per recipient — so "is 6.20 ms per CALL or per RECIPIENT?" decides
 * whether this job has a 48x margin or a 2.4x one. It is neither: the cost is **a fixed per-call
 * term plus a small per-recipient term**, and the per-recipient term is roughly 1/28th of the
 * per-call one. Three further probes, same org, same day, call count held fixed while
 * |recipients| varied, all arms in ONE transaction so they share one CPU clock:
 *
 *   |recipients|   1     2     3     4     5     6     10        ms per send() call
 *   ─────────────────────────────────────────────────────────────
 *   PROBE 4      5.90  6.65  5.80  6.05  6.50  7.25  7.40        (20 calls per arm; 10 at n=10)
 *   PROBE 5      6.24                          7.34              (3 paired rounds x 30 calls)
 *
 *   PROBE 5 slope  (7.344 - 6.244) / 5 = **0.22 ms per additional recipient**
 *
 * PROBE 4 interleaved its arms (1, 6, 2, 5, 3, 4) rather than running them ascending, so a
 * monotonic CPU drift could not be mistaken for recipient scaling, and it repeated the 1-recipient
 * arm last as a drift control: **5.900 both times, exactly.** PROBE 5 is three paired rounds and
 * every round agrees in sign and size. A sixth arm at 10 recipients in an earlier run read 11.30
 * ms per call — the one outlier, taken immediately after an arm that threw 10 caught exceptions;
 * it is kept here as the PESSIMISTIC bound (slope 0.57) rather than discarded.
 *
 * ── THE DERIVATION THAT ACTUALLY GOVERNS, WITH RECIPIENT COUNT AS AN EXPLICIT MULTIPLIER ──
 *
 *   cost of one send()   ≈  6.0 ms  +  0.22 ms x |recipients|
 *   cost of one chunk    ≈  SCOPE x (6.0 + 0.22 x R)          R = queue member count
 *   async CPU budget for a batch execute()  60,000 ms
 *
 *   R      ms per send   200 deals, WORST CASE (every one alerts)   share of 60,000 ms   margin
 *   ────────────────────────────────────────────────────────────────────────────────────────────
 *    1        6.2                    1,240 ms                            ~2.1%            48x
 *   20       10.4                    2,080 ms                            ~3.5%            29x
 *   50       17.0                    3,400 ms                            ~5.7%            17x
 *   20       17.4  (pessimistic slope 0.57)   3,480 ms                   ~5.8%            17x
 *
 * ⇒ **200 STILL HOLDS, AND IT HOLDS WITH ROOM.** Break-even — the recipient count at which a
 * 200-deal chunk would consume the whole 60,000 ms — is **R ≈ 1,336** at the measured slope and
 * **R ≈ 516** at the pessimistic one. Gate G2 expands the `Acquisition` queue from its measured ONE
 * member to the Acquisitions team, i.e. tens; break-even is hundreds. Recompute this table before
 * pointing this job at a group with hundreds of members, and note that the per-call term dominates
 * until R ≈ 27, so at team scale SCOPE is still the thing to reason about, not R.
 *
 * ⚠ THE HONEST LIMITS OF THE MEASUREMENT, BOTH OF THEM:
 *   1. Probe 2 stopped itself at 8,500 ms of a 10,000 ms SYNCHRONOUS budget, so it establishes "no
 *      count ceiling at or below 1,371" and NOT "no count ceiling exists". Anyone raising SCOPE
 *      past ~1,300 must re-measure. Nothing here needs to.
 *   2. The recipient arms reach only **10 real recipients**, because this org has exactly 10 active
 *      users (5 of them platform/automated) and a synthetic recipient Id is REJECTED — see the note
 *      at `GroupNotifier`'s `send()` call. The slope is therefore fitted over 1..10 and
 *      EXTRAPOLATED to 20 and 50 in the table above. It is a straight line over the measured range
 *      with no sign of curvature, but a real 50-member queue has not been observed. If G2 lands a
 *      queue that large, re-run PROBE 5 against it — the arithmetic above is what to redo.
 * ⚠ AND A DAILY ORG ALLOCATION ON CUSTOM NOTIFICATIONS, IF ONE EXISTS, WAS **NOT** MEASURABLE —
 * it appears in neither `Limits` nor `/limits`. This job sends at most one notification per deal
 * per rung, i.e. four per deadline for the life of the deal, so the daily volume is bounded by the
 * live call-for-offers pipeline and is not a number this class can control.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 2. 🔴 SEND FIRST, STAMP SECOND. THE ORDER IS THE DESIGN, NOT AN ACCIDENT.
 * ═══════════════════════════════════════════════════════════════════════════
 * A notification is NOT transactional — once `send()` returns it is out, and no DML rollback
 * recalls it. So the two orders fail in opposite directions and only one is recoverable:
 *
 *   stamp then send  a failed send leaves a marker claiming the alert went out. The alert is lost
 *                    FOREVER and nothing anywhere records it. SILENT.
 *   send then stamp  a failed stamp leaves the deal unmarked, so tomorrow's pass alerts again.
 *                    NOISY, VISIBLE, and self-correcting on the next successful stamp.
 *
 * This job takes the second, and it stamps ONLY the deals whose send actually succeeded — which is
 * the entire reason `GroupNotifier.notifyWithOutcome` was added (see that method's header). Using
 * the old swallow-everything `notify` here would have forced a choice between losing alerts and
 * repeating them daily, which is the failure the marker exists to prevent.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 3. WHERE THE RULES LIVE — NOT HERE
 * ═══════════════════════════════════════════════════════════════════════════
 * Every threshold and the whole idempotency decision are in `CallForOffersService`
 * (`evaluate` / `shouldFire`), which is PURE. This class contributes no ladder of its own — that
 * is what stops the badge on the record page and the alert in someone's bell disagreeing about
 * whether a deal is urgent. If you find yourself writing `7` or `3` in this file, stop.
 *
 * ⚠ THE WHOLE CHUNK IS EVALUATED AGAINST **ONE** `asOf`, captured once at the top of `execute`.
 * Calling `Date.today()` per record would let two deals in one chunk straddle midnight and produce
 * a run in which one deal is "due today" and its neighbour is already "overdue".
 *
 * ⚠ `Call_For_Offers_Received_Date__c` (2026-08-14) IS NOT AN INPUT TO ANYTHING HERE, AND THAT WAS
 * CHECKED RATHER THAN ASSUMED. The marker keys on the DUE date at three points and on nothing else:
 * `shouldFire`'s ladder position comes from `evaluate(Offer_Due_Date__c, asOf)`, its re-arm compares
 * `Offer_Alert_Due_Date__c` against the LIVE `Offer_Due_Date__c`, and the snapshot it stamps is that
 * same live due date. The notification body is `Name + state.detail + broker`, and `detail` is
 * derived from the deadline. So a call-for-offers email that moves ONLY the received date changes no
 * alert decision — correctly: nothing about when the email arrived changes when offers are due.
 * `queryCallForOffersAlerts` therefore deliberately does not select the field, and
 * `queryCallForOffersAlerts_doesNotSelectTheReceivedDate` in `OpportunitySelectorTest` pins that, so
 * adding it later is a decision someone has to take on purpose.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 4. GOVERNOR SHAPE
 * ═══════════════════════════════════════════════════════════════════════════
 * Per `execute()`: **0 SOQL of its own**, at most **1 DML statement**, and at most `SCOPE`
 * notifications — all CONSTANT in the number of deals in the chunk. `GroupNotifier` resolves the
 * queue's recipients at most once per transaction (it caches), so a 200-deal chunk pays the same
 * 3 queries a 1-deal chunk does. A chunk in which nothing is owed an alert costs **zero DML and
 * zero notifications**, which is what makes running this job daily on a quiet pipeline free.
 *
 * ⚠ `Database.Stateful` is carried ONLY for the summary counters. It holds no work state, so a
 * failed chunk loses nothing but its own numbers.
 *
 * ⚠ NOT `Database.AllowsCallouts` — `Messaging.CustomNotification.send()` is not an HTTP callout.
 *
 * ⚠ BULK TESTING: `.claude/rules/bulk-test-rule.md`'s 251-record mandate applies and is met. Note
 * what 251 proves here: a test method executes only ONE chunk, so at SCOPE = 200 a 251-row fixture
 * proves the LOCATOR selects, filters and orders 251 rows and that a full 200-deal chunk behaves —
 * it does not drive two `execute()` calls.
 *
 * @see CallForOffersService.cls          (every threshold, and `shouldFire` — the marker rule)
 * @see CallForOffersAlertSchedule.cls    (🔴 the post-deploy scheduling gate)
 * @see OpportunitySelector.queryCallForOffersAlerts (the work queue — SYSTEM_MODE, and its residual)
 * @see GroupNotifier.notifyWithOutcome   (why the outcome list exists)
 * @see DealFolderSweepBatch.cls          (the shape this follows — and the SCOPE that is NOT copied)
 */
public with sharing class CallForOffersAlertBatch implements Database.Batchable<SObject>, Database.Stateful {

    /**
     * 🔴 Deals per transaction. A BLAST-RADIUS choice against a MEASURED cost of
     * `6.0 ms + 0.22 ms x |recipients|` per notification — ~2.1% of the 60,000 ms async CPU budget
     * at this size with the queue's measured ONE member, and ~3.5% at twenty. It is NOT a
     * notification-count budget: 1,371 sends in one transaction were measured with no ceiling
     * reached. 🔴 QUOTE THE RECIPIENT COUNT WITH THE MILLISECONDS, always — the bare "6.20 ms"
     * figure is the R = 1 case and reads as a constant when it is a function. Full derivation, the
     * five probes and the break-even arithmetic are in the class header §1. Do not raise it past
     * ~1,300 without re-measuring, and recompute §1's table before pointing this job at a group
     * with hundreds of members.
     */
    public static final Integer SCOPE = 200;

    /**
     * The alerting population. A queue is a valid custom-notification recipient even though the
     * `Acquisition` queue's `queueSobject` list is `Lead` and `Property__c` and NOT `Opportunity`
     * (requirements §9 C10) — it can be told about a deal it cannot own. Confirming that this queue's
     * MEMBERSHIP is the intended alerting population is post-deploy gate G2; queue membership is not
     * deployable metadata and no test can see it.
     *
     * ⚠ NOT `final`, and that is a TEST SEAM rather than an oversight: pointing it at a group that
     * does not exist is the only way to reproduce a swallowed send failure, which is the branch that
     * proves a failed alert is NOT stamped. There is no other way to make `GroupNotifier` fail on
     * demand, and that branch is the reason `notifyWithOutcome` exists at all.
     */
    @TestVisible
    private static String RECIPIENT_GROUP = 'Acquisition';

    // ═══════════════════════════════════════════════════════════════════════
    // COUNTERS — TWO SETS, ON PURPOSE. THEY ANSWER DIFFERENT QUESTIONS.
    //
    // The `chunk*` STATICS are reset at the top of every `execute()` and describe THAT CHUNK. They
    // exist because a test cannot read the instance fields below: `Database.Stateful` serialises the
    // batch instance, so the object the test handed to `Database.executeBatch` is NOT the object
    // that ran and its fields never move. Statics captured INSIDE the async transaction are the
    // repo's established way round that (`ExtractAddressQueueable.lastRunQueryCount` is the
    // precedent) — and note the matching trap: `Test.stopTest()` restores the pre-test governor
    // counters, so asserting `Limits.*` afterwards is silently vacuous.
    //
    // The `total*` INSTANCE fields accumulate ACROSS chunks and are what `finish()` reports. A test
    // running a single chunk cannot see them; production, running many, needs them.
    // ═══════════════════════════════════════════════════════════════════════

    /** Deals the last `execute()` looked at. */
    @TestVisible
    private static Integer chunkEvaluated = 0;
    /** Deals the last `execute()` decided were owed an alert. */
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
    }

    /**
     * The work queue: open deals whose call-for-offers deadline is inside the alert ladder.
     *
     * @param ctx The batch context (unused; required by the interface).
     * @return A locator over candidate deals, soonest deadline first.
     */
    public Database.QueryLocator start(Database.BatchableContext ctx) {
        return OpportunitySelector.queryCallForOffersAlerts();
    }

    /**
     * Alert on one chunk. See the class header §2 for why the order is send-then-stamp.
     *
     * FAIL-SOFT PER CHUNK: a batch has no Finalizer, so a failure here is recorded here or nowhere.
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
        try {
            // ONE clock for the whole chunk — see the class header §3.
            Date asOf = Date.today();

            List<GroupNotifier.Request> requests = new List<GroupNotifier.Request>();
            // Index-aligned with `requests`: the marker each successful send earns.
            List<Opportunity> pendingStamps = new List<Opportunity>();

            for (Opportunity deal : scope) {
                if (deal == null || deal.Id == null) {
                    continue;
                }
                chunkEvaluated++;
                CallForOffersService.CallForOffers state =
                    CallForOffersService.evaluate(deal.Offer_Due_Date__c, asOf);

                // Number -> Integer: the field is Number(2,0), so it arrives as a Decimal.
                Integer lastInterval = (deal.Offer_Alert_Last_Interval__c == null)
                    ? null
                    : deal.Offer_Alert_Last_Interval__c.intValue();

                if (!CallForOffersService.shouldFire(
                        state.dueInterval, lastInterval,
                        deal.Offer_Due_Date__c, deal.Offer_Alert_Due_Date__c)) {
                    continue;
                }
                chunkOwed++;
                requests.add(buildRequest(deal, state));
                pendingStamps.add(new Opportunity(
                    Id = deal.Id,
                    Offer_Alert_Last_Interval__c = state.dueInterval,
                    // The SNAPSHOT — see CallForOffersService §3. Storing the LIVE due date is what
                    // lets a later change to it re-arm the whole ladder by itself.
                    Offer_Alert_Due_Date__c = deal.Offer_Due_Date__c
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
                'CallForOffersAlertBatch: chunk of ' + scope.size() + ' failed: '
                + e.getTypeName() + ' | ' + e.getMessage()
                + ' | the deals are untouched and stay in the queue for the next pass.');
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
     * Write the alert markers for the deals that were actually notified.
     *
     * 🔴 `AccessLevel.SYSTEM_MODE`, and it is a THIRD decision — implied by neither the selector's
     * mode nor its sharing. Both marker fields are Metadata-API-deployed custom fields, which arrive
     * with NO field permissions for ANY profile, System Administrator included, so a user-mode write
     * would refuse on day one for the very administrator who deployed them. No principal asked for
     * this write; the scheduler makes it on the team's behalf, and nothing about it is a human's
     * edit to a deal.
     *
     * 🔴 `allOrNone = false`, deliberately: one refused row must not cost the other 199 their
     * markers, because an unstamped-but-notified deal alerts AGAIN tomorrow. Partial success is the
     * strictly better outcome here.
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
            // A lost marker is NOISY, not silent — the deal re-alerts next pass. Recorded so the
            // cause is findable, because the symptom (a repeating alert) points somewhere else.
            String detail = results[i].getErrors().isEmpty()
                ? 'no error detail'
                : results[i].getErrors()[0].getStatusCode() + ': ' + results[i].getErrors()[0].getMessage();
            System.debug(LoggingLevel.WARN,
                'CallForOffersAlertBatch: alert SENT but marker NOT stamped for '
                + toStamp[i].Id + ' (' + detail + '). This deal will alert again on the next pass.');
        }
    }

    /**
     * The notification for one deal. Every string comes from the shared service, so the bell, the
     * badge and the table cannot describe the same deadline three different ways.
     *
     * @param deal  The deal being alerted on.
     * @param state Its computed call-for-offers state.
     * @return The notification request.
     */
    private GroupNotifier.Request buildRequest(
        Opportunity deal,
        CallForOffersService.CallForOffers state
    ) {
        GroupNotifier.Request request = new GroupNotifier.Request();
        request.recipientGroup = RECIPIENT_GROUP;
        request.targetRecordId = deal.Id;
        request.title = 'Offers due: ' + state.label;
        String broker = String.isBlank(deal.Listing_Broker_Name__c)
            ? ''
            : ' Listing broker: ' + deal.Listing_Broker_Name__c + '.';
        request.body = deal.Name + ' — ' + state.detail + broker;
        return request;
    }

    /**
     * Summarise the pass. Deliberately a debug line and nothing more: the durable record of what was
     * alerted lives on each deal's own two marker fields, which are queryable and reportable —
     * unlike a static or a log line.
     *
     * @param ctx The batch context (unused).
     */
    public void finish(Database.BatchableContext ctx) {
        System.debug(LoggingLevel.INFO,
            'CallForOffersAlertBatch finished: evaluated=' + totalEvaluated
            + ' owed=' + totalOwed
            + ' notified=' + totalNotified
            + ' stamped=' + totalStamped
            + ' sendFailures=' + totalSendFailures
            + ' failedChunks=' + failedChunks);
    }
}
