/**
 * THE NIGHTLY BROKER COUNTER RECALCULATION. Maintains four fields on every broker Contact —
 * `Deals_Submitted__c`, `Deals_Won__c`, `Deals_Lost__c` and `First_Submission_DateTime__c` — so
 * the Contact page stops rendering the permanent zeroes it has shown since those fields were
 * created with no writer at all.
 *
 * Design §2 ITEM 6.2/6.4 (2026-08-30 user decision Q6). Scheduled by
 * `BrokerCounterRecalcSchedule`.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════
 * §0 🔴 READ `BrokerLeaderboardService`'s HEADER BEFORE CHANGING ANYTHING HERE. IT ARGUES
 *     AGAINST THIS CLASS IN THREE NUMBERED REASONS, AND TWO OF THEM ARE STILL CORRECT.
 * ═══════════════════════════════════════════════════════════════════════════════════════
 * That header says Contact counters are the wrong home for broker statistics. It was put to
 * the user verbatim, the user AGREED, and then **narrowed the scope** rather than cancelling
 * the work. This class is the narrowed version. Each of the three reasons has a specific,
 * different status, and collapsing them is how the argument gets re-run in six months:
 *
 *   1. 🔴 **STILL TRUE, AND IT IS THIS CLASS'S PERMANENT LIMITATION — NOT A BUG TO FILE.**
 *      *"Most brokers in the ledger have no Contact and never will."* Since 2026-07-31 a
 *      COMPETING (losing) broker receives no Lead, so no conversion, so no Contact, ever.
 *      These four fields can therefore only ever describe the subset that WON and CONVERTED.
 *      🔴 **THE LEADERBOARD REMAINS AUTHORITATIVE AND IS DELIBERATELY UNTOUCHED BY THIS
 *      CHANGE.** `BrokerLeaderboardService` still computes live from
 *      `Competing_Broker_Submission__c`, which is the only surface that sees losing brokers.
 *      **DO NOT REPOINT IT AT Contact.** If these numbers and the leaderboard disagree, the
 *      leaderboard is right and this is a narrower population — that is the design, and the
 *      four field `<description>`s say so on the fields themselves.
 *
 *   2. 🔴 **STILL TRUE, AND IT IS A HARD BOUNDARY ON WHAT THIS JOB MAY WRITE.**
 *      `Active_Listings__c`, `Closed_Volume__c` and `Avg_Days_On_Market__c` are the
 *      **disposition-side** broker scorecard and mean something else entirely. This batch
 *      does not read them, does not write them, and must never be extended to. They are not
 *      even in the locator's select list.
 *
 *   3. ✅ **DOES NOT APPLY HERE, AND SAYING SO IS THE POINT.** Reason 3 warns that a rollup
 *      would need *"Apex plus a fuzzy email match … under which a broker with two addresses
 *      becomes ONE SILENTLY UNDERCOUNTED Contact."* **THERE IS NO EMAIL MATCHING IN THIS
 *      CLASS, FUZZY OR OTHERWISE.** That warning was about `Competing_Broker_Submission__c`,
 *      whose broker identity is a **Text email with no Contact lookup**. This batch never
 *      touches that object. It keys on `Opportunity.Broker__c` and `Lead.ConvertedContactId`,
 *      both **real Contact lookups** stamped by `LeadConvertService`
 *      (`o.Broker__c = l.ConvertedContactId`), so both joins are exact Id joins and a broker
 *      with two email addresses is one Contact Id by construction. Recorded here explicitly so
 *      the warning is not re-inherited by the next reader.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════
 * §1 🔴 IT BATCHES OVER **CONTACT**, NOT OVER OPPORTUNITY — AND THAT IS THE WHOLE DESIGN
 * ═══════════════════════════════════════════════════════════════════════════════════════
 * The locator is `ContactSelector.queryBrokerCounterTargets()`: every Contact on the
 * `Contact.Broker` record type, unfiltered.
 *
 * The Opportunity-rooted alternative is the one that looks natural — aggregate the deals, write
 * the brokers you found — and it is **wrong in a way that never surfaces as an error**. It only
 * ever visits a broker who currently HAS deals. A broker whose deals were deleted, reassigned to
 * another broker, or merged away is never visited, so their old count survives forever and reads
 * as a live number. An Opportunity-rooted job can only ever make counts go UP.
 *
 * Rooting at Contact means **every broker in scope is written**, so a broker with no deals is
 * reset to **0** and a broker with no Lead is reset to **null**. `resetsStaleCountersToZero` in
 * the test class is the falsifier for this decision and is the single most important test here.
 *
 * ⚠ THE COROLLARY, WHICH IS EASY TO MISS: because this job RESETS, every read it depends on
 * fails DESTRUCTIVELY rather than incompletely. A read that returns nothing does not leave the
 * counters stale — it overwrites correct values with zeroes and nulls, silently, nightly. That
 * is why the sharing question was MEASURED at each selector method instead of inherited, and why
 * the two halves reached OPPOSITE answers (§3).
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════
 * §2 GOVERNOR BUDGET — **2 SOQL / AT MOST 1 DML PER CHUNK, CONSTANT IN THE NUMBER OF DEALS**
 * ═══════════════════════════════════════════════════════════════════════════════════════
 *   • 1 aggregate over Opportunity  (`OpportunitySelector.aggregateDealCountsByBroker`)
 *   • 1 aggregate over Lead         (`LeadSelector.aggregateFirstSeenByConvertedContact`)
 *   • at most 1 `Database.update`   (skipped entirely when nothing changed)
 *
 * There is no query and no DML per broker and none per deal. `chunkQueries` / `chunkDmlStatements`
 * pin this in the test class — the assertion is the CONSTANT-ness, not the count.
 *
 * 🔴 THIS SHAPE IS THE WHOLE REASON THE WORK IS A NIGHTLY BATCH AND NOT A TRIGGER. Routing a
 * parent read + parent DML into `OpportunityReviewTrigger` — which already fans out to five
 * services, one of which enqueues a Queueable under a never-throw contract and another of which
 * throws by design — is the exact shape of a MEASURED incident on this project: a new parent
 * routed into a Task trigger cost `ceil(rows/200)` SOQL **and** DML, 23 of each at production
 * scale. That trigger was also widened for design ITEM 2 in this same programme, which would have
 * made any regression unattributable. Do not "make the counters live".
 *
 * ── §2a WHY `SCOPE = 100` AND NOT THE 200 EVERY OTHER BATCH HERE INHERITS ────────────────
 * 🔴 THIS ONE IS DERIVED, NOT INHERITED, AND IT GUARDS A HARD PLATFORM CLIFF.
 * `OpportunitySelector.aggregateDealCountsByBroker` groups by `Broker__c` **and** `StageName`, so
 * it returns up to `|brokers in chunk| × |distinct stages they occupy|` rows. An aggregate query
 * assigned to a `List<AggregateResult>` **throws above 2,000 rows**.
 *
 *     Opportunity.StageName has 10 values (OpportunityStage.standardValueSet, counted 2026-08-31)
 *     SCOPE = 200  ->  200 × 10 = 2,000 rows  ->  EXACTLY AT THE CLIFF
 *     SCOPE = 100  ->  100 × 10 = 1,000 rows  ->  2× headroom; survives up to 20 stages
 *
 * At 200 the job would work perfectly until a chunk happened to contain 200 brokers spread across
 * all ten stages, then throw inside `execute()`, be swallowed by the fail-soft catch in §4, and
 * leave those brokers stale with only a debug line to say so. Halving the scope costs nothing
 * measurable here: a chunk does 2 queries and no callouts and no notifications, and the live
 * roster is 18 brokers (measured 2026-08-31) — one chunk.
 * 🔴 **ADDING AN OPPORTUNITY STAGE NARROWS THIS HEADROOM. REDO THE ARITHMETIC ABOVE, HERE, IF YOU
 * DO.** Do not copy 200 in from `CallForOffersAlertBatch` / `NdaExpiryAlertBatch`; their locators
 * have no per-row multiplier and the number does not transfer.
 *
 * ── §2b THE NO-OP SKIP, WHICH IS WHY A QUIET NIGHT COSTS ZERO DML ROWS ───────────────────
 * The locator selects the four CURRENT values, and a Contact is added to the update list only if
 * at least one of them actually differs from the computed value. Over a stable roster the nightly
 * pass therefore writes NOTHING — no `LastModifiedDate` churn, no field history, no downstream
 * trigger fan-out from a job that changed nothing. `quietRunWritesNothing` pins it.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════
 * §3 🔴 MODE AND SHARING — THREE READS, THREE SEPARATE MEASUREMENTS, TWO DIFFERENT ANSWERS
 * ═══════════════════════════════════════════════════════════════════════════════════════
 * All three reads are `WITH SYSTEM_MODE` (ARCHITECTURE.md §2 automation path — a nightly
 * scheduler reads on the team's behalf, and two of the four Contact fields are new customs that
 * arrive with **no FLS for any profile, System Administrator included**). Each mode is argued at
 * its own declaration in the selector, never borrowed.
 *
 * 🔴 **`SYSTEM_MODE` LIFTS CRUD AND FLS AND NEVER SHARING.** That was asked as a separate question
 * per read, against the live org via the Tooling API on **2026-08-31**, and the answers differ:
 *
 * | Read                                   | Object OWD (measured)      | Sharing verdict            |
 * |----------------------------------------|----------------------------|----------------------------|
 * | `ContactSelector.queryBrokerCounterTargets` | Contact `ReadWrite`   | 🔴 **ESCAPE REQUIRED**     |
 * | `OpportunitySelector.aggregateDealCountsByBroker` | Opportunity `ReadWrite` | ✅ `with sharing` suffices |
 * | `LeadSelector.aggregateFirstSeenByConvertedContact` | Lead `Private` | 🔴 **ESCAPE REQUIRED**     |
 *
 *   • **Opportunity = `ReadWrite`.** Every internal principal already sees every deal, so the
 *     deal aggregate cannot under-count for a sharing reason and stays `with sharing`.
 *     ⚠ The Item 6 task brief asserted *"Opportunity OWD is Private"*. **It is not** — that was
 *     checked rather than believed, because an under-count here would have been invisible.
 *
 *   • **Lead = `Private`.** A `with sharing` read returns only the Leads the SCHEDULING PRINCIPAL
 *     owns. Combined with §1's reset semantics that does not under-report — it **erases
 *     `First_Submission_DateTime__c` across the entire broker roster every night**, and an
 *     all-nulls result is indistinguishable from "no broker has ever been seen". Escaped via
 *     `LeadSelector.BrokerFirstSeenReads`.
 *
 *   • **Contact = `ReadWrite`, AND THAT READING IS MISLEADING.** A Contact with **no `AccountId`
 *     is a private contact, visible only to its owner, whatever the OWD says.** Measured the same
 *     day: **4 of this org's 18 broker Contacts (22%) have a null `AccountId`.** Under sharing
 *     those four are never visited by a non-owning scheduler and keep a stale count forever —
 *     reintroducing, through the back door, the exact failure §1 chose a Contact-rooted batch to
 *     prevent. Escaped via `ContactSelector.CounterTargetReads`.
 *
 * ── §3a WHY THE **WRITE** ALSO ESCAPES, AND WHY THE OUTER CLASS IS `without sharing` ─────
 * The same account-less rule governs the UPDATE: a private Contact owned by someone else is not
 * editable by the scheduler, and with `allOrNone = false` that refusal is a `SaveResult`, not an
 * exception — **silent**. This project has already paid for that combination once (an approval's
 * parent write failed for every approver who did not own the record). Hence `CounterWrites`.
 *
 * The OUTER class is `without sharing` too, copying `NdaExpiryAlertBatch`'s resolution of the same
 * open question: it is not established whether the platform re-applies the BATCH class's sharing
 * context when it chunks a `QueryLocator` that was built inside a `without sharing` selector. The
 * two are **not redundant and neither may be deleted on the strength of the other** — the outer
 * keyword removes that unknown, `CounterWrites` is the deliberate, argued escape for the DML, and
 * narrowing the outer class must not silently un-escape the write.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════
 * §4 FAIL-SOFT PER CHUNK
 * ═══════════════════════════════════════════════════════════════════════════════════════
 * A batch has no Finalizer, so a failure is recorded here or nowhere. A chunk that throws leaves
 * its brokers' counters exactly as they were and is picked up by the next nightly pass — the job
 * is fully idempotent, so a missed night costs nothing. The catch exists so one bad chunk cannot
 * abort the rest.
 *
 * ⚠ THE COUNTERS THIS JOB WRITES ARE NOT A DURABLE LOG OF WHAT IT DID — they are a snapshot of
 * what is true. Unlike the alert jobs' markers, you cannot tell from a Contact whether the last
 * pass ran. `finish()`'s debug line is the only record, which is acceptable precisely because a
 * skipped pass is self-healing.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════
 * §5 WHAT IS DELIBERATELY ABSENT
 * ═══════════════════════════════════════════════════════════════════════════════════════
 *   • **WIN RATE and LAST SUBMISSION are NOT stored.** `BrokerLeaderboardService` already
 *     computes both, in Apex, specifically so that *"two surfaces computing their own ranks"*
 *     cannot disagree. If a reporting need appears, the honest form is a FORMULA over the two
 *     stored counts — never a fifth maintained Number.
 *   • **No `@InvocableMethod`.** N/A for a scheduled recalculation with no per-record input; a
 *     Flow that wanted an on-demand pass would call `Database.executeBatch`, and exposing a
 *     whole-org recalculation to Flow invites one job per record.
 *   • **No incremental / `LastModifiedDate`-windowed mode.** It would reintroduce §1's bug: a
 *     broker whose deals were deleted has no recently-modified anything.
 *
 * LAYER — Batch. Zero SOQL of its own: every read goes through a selector per ARCHITECTURE.md §2
 * and `.claude/rules/apex-layering-rule.md`. The only DML is the counter write in §3a.
 *
 * @see BrokerCounterRecalcSchedule.cls  (the nightly trigger, and the post-deploy gate)
 * @see BrokerLeaderboardService.cls     (🔴 AUTHORITATIVE broker population — read §0)
 * @see ContactSelector.cls              (the locator, and the account-less measurement)
 * @see OpportunitySelector.cls          (the deal aggregate, and the 2,000-row cliff)
 * @see LeadSelector.cls                 (the first-seen aggregate, and the Lead=Private escape)
 */
public without sharing class BrokerCounterRecalcBatch implements Database.Batchable<SObject>, Database.Stateful {

    /**
     * Contacts per chunk. 🔴 **100, DERIVED — NOT the 200 the sibling batches inherit.** The full
     * arithmetic, and the instruction to redo it if an Opportunity stage is ever added, is in the
     * class header §2a. Do not raise this without reading it.
     */
    public static final Integer SCOPE = 100;

    /** The `StageName` that counts as a WIN. Design §2 ITEM 6.2. */
    @TestVisible
    private static final String STAGE_WON = 'Closed Won';

    /**
     * The `StageName` that counts as a LOSS.
     * ⚠ The value is literally `Dead/Pass` — NOT `Dead`. (`Dead%2FPass` is a URL-encoded form that
     * appears ONLY inside `BusinessProcess` / `RecordType` metadata; do not use it in Apex, and do
     * not "correct" either form.)
     */
    @TestVisible
    private static final String STAGE_LOST = 'Dead/Pass';

    // ═══════════════════════════════════════════════════════════════════════
    // COUNTERS — TWO SETS, ON PURPOSE. THEY ANSWER DIFFERENT QUESTIONS.
    //
    // The `chunk*` STATICS are reset at the top of every `execute()` and describe THAT CHUNK.
    // They exist because a test CANNOT read the instance fields below: `Database.Stateful`
    // serialises the batch instance, so the object handed to `Database.executeBatch` is NOT the
    // object that ran and its fields never move. Statics captured INSIDE the async transaction
    // are this repo's established way round that (`NdaExpiryAlertBatch.chunkEvaluated`,
    // `ExtractAddressQueueable.lastRunQueryCount`) — and note the matching trap:
    // `Test.stopTest()` RESTORES the pre-test governor counters, so asserting `Limits.*` after
    // it is silently vacuous. `chunkQueries` / `chunkDmlStatements` are captured in-context for
    // exactly that reason.
    //
    // The `total*` INSTANCE fields accumulate ACROSS chunks and are what `finish()` reports.
    // ═══════════════════════════════════════════════════════════════════════

    /** Broker Contacts the last `execute()` looked at. */
    @TestVisible
    private static Integer chunkEvaluated = 0;
    /** Broker Contacts whose computed counters DIFFERED from what was stored. */
    @TestVisible
    private static Integer chunkChanged = 0;
    /** Counter rows the last `execute()` successfully committed. */
    @TestVisible
    private static Integer chunkUpdated = 0;
    /** Counter rows the write REFUSED (sharing, validation). Silent without this. */
    @TestVisible
    private static Integer chunkWriteFailures = 0;
    /** SOQL statements the last `execute()` issued. Pins "2, constant in chunk size". */
    @TestVisible
    private static Integer chunkQueries = 0;
    /** DML statements the last `execute()` issued. Pins "at most 1, constant in chunk size". */
    @TestVisible
    private static Integer chunkDmlStatements = 0;

    /** Cross-chunk totals for `finish()`; see the block comment above. */
    private Integer totalEvaluated = 0;
    private Integer totalChanged = 0;
    private Integer totalUpdated = 0;
    private Integer totalWriteFailures = 0;
    /** Chunks whose work threw. Those brokers' counters are untouched; next pass retries. */
    private Integer failedChunks = 0;

    /** Zero the per-chunk statics. Called at the top of every `execute()`. */
    @TestVisible
    private static void resetChunkCounters() {
        chunkEvaluated = 0;
        chunkChanged = 0;
        chunkUpdated = 0;
        chunkWriteFailures = 0;
        chunkQueries = 0;
        chunkDmlStatements = 0;
    }

    /**
     * The work queue: EVERY broker Contact, unfiltered. See the class header §1 for why there is
     * no narrowing predicate and what adding one would break.
     *
     * @param ctx The batch context (unused; required by the interface).
     * @return A locator over every Broker-record-type Contact with its four current counters.
     */
    public Database.QueryLocator start(Database.BatchableContext ctx) {
        return ContactSelector.queryBrokerCounterTargets();
    }

    /**
     * Recalculate one chunk of brokers.
     *
     * Two aggregates and an in-memory merge — never a query per broker and never one per deal.
     * A broker ABSENT from the deal aggregate is not skipped; they are resolved to zeroes, which
     * is the reset in the class header §1.
     *
     * @param ctx   The batch context (unused).
     * @param scope The broker Contacts to recalculate; at most `SCOPE`.
     */
    public void execute(Database.BatchableContext ctx, List<Contact> scope) {
        resetChunkCounters();
        if (scope == null || scope.isEmpty()) {
            return;
        }
        try {
            Set<Id> brokerIds = new Set<Id>();
            for (Contact broker : scope) {
                if (broker != null && broker.Id != null) {
                    brokerIds.add(broker.Id);
                }
            }
            if (brokerIds.isEmpty()) {
                return;
            }

            chunkQueries++;
            Map<Id, DealCounts> countsByBroker =
                foldDealCounts(OpportunitySelector.aggregateDealCountsByBroker(brokerIds));

            chunkQueries++;
            Map<Id, Datetime> firstSeenByBroker =
                foldFirstSeen(LeadSelector.aggregateFirstSeenByConvertedContact(brokerIds));

            List<Contact> toUpdate = new List<Contact>();
            for (Contact broker : scope) {
                if (broker == null || broker.Id == null) {
                    continue;
                }
                chunkEvaluated++;
                // ABSENT means ZERO, not "leave alone" — the class header §1 reset.
                DealCounts counts = countsByBroker.get(broker.Id);
                if (counts == null) {
                    counts = new DealCounts();
                }
                Datetime firstSeen = firstSeenByBroker.get(broker.Id);

                if (!isChanged(broker, counts, firstSeen)) {
                    continue;
                }
                chunkChanged++;
                toUpdate.add(new Contact(
                    Id = broker.Id,
                    Deals_Submitted__c = counts.submitted,
                    Deals_Won__c = counts.won,
                    Deals_Lost__c = counts.lost,
                    First_Submission_DateTime__c = firstSeen
                ));
            }

            if (!toUpdate.isEmpty()) {
                commitCounters(toUpdate);
            }
            accumulate();
        } catch (Exception e) {
            failedChunks++;
            accumulate();
            System.debug(LoggingLevel.ERROR,
                'BrokerCounterRecalcBatch: chunk of ' + scope.size() + ' failed: '
                + e.getTypeName() + ' | ' + e.getMessage()
                + ' | those brokers keep their previous counters and are retried next pass.');
        }
    }

    /** Roll this chunk's statics into the cross-chunk totals `finish()` reports. */
    private void accumulate() {
        totalEvaluated += chunkEvaluated;
        totalChanged += chunkChanged;
        totalUpdated += chunkUpdated;
        totalWriteFailures += chunkWriteFailures;
    }

    /**
     * The three deal counts for one broker. A tiny holder rather than three parallel Maps: the
     * three numbers are always produced, consumed and compared together, and three Maps would let
     * a future edit update one and forget the others.
     */
    @TestVisible
    private class DealCounts {
        /** Every Opportunity naming this broker. */
        private Integer submitted = 0;
        /** Those at `STAGE_WON`. */
        private Integer won = 0;
        /** Those at `STAGE_LOST`. */
        private Integer lost = 0;
    }

    /**
     * Fold the `GROUP BY Broker__c, StageName` aggregate into one `DealCounts` per broker.
     *
     * ⚠ EVERY row contributes to `submitted`; only the two terminal stages additionally
     * contribute to `won` / `lost`. That is what makes `submitted` mean "all deals" rather than
     * "open deals" — the design's definition (§2 ITEM 6.2), and the reason the query carries no
     * stage predicate.
     *
     * @param rows Aggregate rows with aliases `brokerId`, `st` and `c`; may be empty.
     * @return Counts keyed by broker Contact Id; brokers with no deals are ABSENT (the caller
     *         resolves absence to zeroes). Never null.
     */
    @TestVisible
    private static Map<Id, DealCounts> foldDealCounts(List<AggregateResult> rows) {
        Map<Id, DealCounts> byBroker = new Map<Id, DealCounts>();
        if (rows == null) {
            return byBroker;
        }
        for (AggregateResult row : rows) {
            Id brokerId = (Id) row.get('brokerId');
            if (brokerId == null) {
                continue;
            }
            DealCounts counts = byBroker.get(brokerId);
            if (counts == null) {
                counts = new DealCounts();
                byBroker.put(brokerId, counts);
            }
            Integer atStage = intOf(row.get('c'));
            counts.submitted += atStage;
            String stage = (String) row.get('st');
            if (STAGE_WON.equals(stage)) {
                counts.won += atStage;
            } else if (STAGE_LOST.equals(stage)) {
                counts.lost += atStage;
            }
        }
        return byBroker;
    }

    /**
     * Fold the `MIN(First_Seen_Date__c) GROUP BY ConvertedContactId` aggregate into a map.
     *
     * @param rows Aggregate rows with aliases `contactId` and `firstSeen`; may be empty.
     * @return The earliest first-seen instant keyed by broker Contact Id; brokers with no such
     *         Lead are ABSENT (the caller resolves absence to null). Never null.
     */
    @TestVisible
    private static Map<Id, Datetime> foldFirstSeen(List<AggregateResult> rows) {
        Map<Id, Datetime> byBroker = new Map<Id, Datetime>();
        if (rows == null) {
            return byBroker;
        }
        for (AggregateResult row : rows) {
            Id contactId = (Id) row.get('contactId');
            if (contactId == null) {
                continue;
            }
            byBroker.put(contactId, (Datetime) row.get('firstSeen'));
        }
        return byBroker;
    }

    /**
     * Does this broker's stored state differ from what was just computed?
     *
     * 🔴 THIS IS WHAT MAKES A QUIET NIGHT COST ZERO DML ROWS (class header §2b), and it must
     * treat NULL and 0 as DIFFERENT. On day one every counter is null while the computed value is
     * 0, so `null != 0` is precisely what triggers the initial backfill; collapsing them (e.g.
     * `intOf(stored) != computed`) would make the fields stay null forever for every broker with
     * no deals, and the permanent-zeroes complaint would simply become permanent blanks.
     *
     * ⚠ The stored values arrive as `Decimal` (the fields are Number(18,0)), so they are narrowed
     * to `Integer` before comparison — `Decimal` and `Integer` do not compare equal by `==` in
     * every combination, and an accidental always-true here would rewrite the whole roster nightly.
     *
     * @param stored    The Contact as read by the locator, carrying its current four values.
     * @param counts    The freshly computed deal counts; never null.
     * @param firstSeen The freshly computed first-submission instant; may be null.
     * @return true when at least one of the four values needs writing.
     */
    @TestVisible
    private static Boolean isChanged(Contact stored, DealCounts counts, Datetime firstSeen) {
        Integer storedSubmitted = intOrNull(stored.Deals_Submitted__c);
        Integer storedWon = intOrNull(stored.Deals_Won__c);
        Integer storedLost = intOrNull(stored.Deals_Lost__c);
        return storedSubmitted != counts.submitted
            || storedWon != counts.won
            || storedLost != counts.lost
            || stored.First_Submission_DateTime__c != firstSeen;
    }

    /**
     * Commit the recalculated counters and record what the write actually did.
     *
     * 🔴 THREE DECISIONS, NONE IMPLIED BY THE OTHERS — see the class header §3/§3a:
     *
     *  1. `AccessLevel.SYSTEM_MODE` — `Deals_Lost__c` and `First_Submission_DateTime__c` are
     *     Metadata-API-deployed customs, which arrive with NO field permissions for ANY profile,
     *     System Administrator included, so a user-mode write would refuse on day one for the very
     *     administrator who deployed them. No principal asked for this write.
     *  2. `allOrNone = false` — one refused broker must not cost the other 99 their counters.
     *     Partial success is strictly better for an idempotent, self-healing job.
     *  3. 🔴 **`without sharing`, via `CounterWrites`** — and this is NOT covered by (1).
     *     SYSTEM_MODE lifts CRUD/FLS and NEVER sharing, and an ACCOUNT-LESS Contact is
     *     owner-private regardless of Contact's `ReadWrite` OWD (4 of 18 measured 2026-08-31).
     *     Combined with (2) that refusal would be SILENT — a `SaveResult`, not an exception.
     *
     * @param toUpdate Counter-only Contact shells; never empty when called.
     */
    private void commitCounters(List<Contact> toUpdate) {
        chunkDmlStatements++;
        List<Database.SaveResult> results = new CounterWrites().saveCounters(toUpdate);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                chunkUpdated++;
                continue;
            }
            chunkWriteFailures++;
            // A refused counter is otherwise INVISIBLE: the Contact simply keeps yesterday's
            // number, which looks exactly like a correct one. Recorded so the cause is findable.
            String detail = results[i].getErrors().isEmpty()
                ? 'no error detail'
                : results[i].getErrors()[0].getStatusCode() + ': ' + results[i].getErrors()[0].getMessage();
            System.debug(LoggingLevel.WARN,
                'BrokerCounterRecalcBatch: counters NOT written for ' + toUpdate[i].Id
                + ' (' + detail + '). This broker keeps its previous, now-stale counters.');
        }
    }

    /**
     * 🔴 THE COUNTER WRITE, WHICH MUST RUN **WITHOUT SHARING**, AND NOTHING ELSE.
     *
     * The `NdaExpiryAlertBatch.MarkerWrites` shape, for a related but distinct reason: there the
     * object is Private OWD; here the object measures `ReadWrite` and the exposure comes from the
     * ACCOUNT-LESS-Contact rule, which the OWD does not describe. The full argument is at
     * `commitCounters` and in the class header §3a.
     *
     * 🔴 THIS AND THE OUTER `without sharing` KEYWORD ARE NOT REDUNDANT AND NEITHER MAY BE DELETED
     * ON THE STRENGTH OF THE OTHER. The outer keyword exists to remove an UNKNOWN about the
     * sharing context of a chunked `QueryLocator` (an argument, not a measurement); this inner
     * class is the DELIBERATE, MEASURED escape for the WRITE, and it is what a reader finds when
     * they ask why this DML escapes sharing. Deleting it would make the escape an accidental side
     * effect of a keyword two hundred lines away that was added for a different reason.
     */
    private without sharing class CounterWrites {

        /**
         * Commit the counter updates, without sharing.
         *
         * @param toUpdate Counter-only `Contact` shells carrying an Id and the four counter
         *                 fields; the caller owns every decision about what is in the list.
         * @return One `Database.SaveResult` per row, in input order.
         */
        private List<Database.SaveResult> saveCounters(List<Contact> toUpdate) {
            return Database.update(toUpdate, false, AccessLevel.SYSTEM_MODE);
        }
    }

    /**
     * Summarise the pass. Deliberately a debug line and nothing more — but note the asymmetry with
     * the alert jobs called out in the class header §4: those leave a durable per-record marker,
     * whereas a counter is a snapshot and cannot tell you whether the last pass ran. That is
     * acceptable only because a skipped pass is self-healing.
     *
     * @param ctx The batch context (unused).
     */
    public void finish(Database.BatchableContext ctx) {
        System.debug(LoggingLevel.INFO,
            'BrokerCounterRecalcBatch finished: evaluated=' + totalEvaluated
            + ' changed=' + totalChanged
            + ' updated=' + totalUpdated
            + ' writeFailures=' + totalWriteFailures
            + ' failedChunks=' + failedChunks);
    }

    /**
     * `COUNT(Id)` comes back as an Integer-valued Object; this narrows it without assuming the
     * runtime type.
     *
     * @param value The aggregate value.
     * @return The value as an Integer, or 0 when null.
     */
    private static Integer intOf(Object value) {
        return (value == null) ? 0 : Integer.valueOf(value);
    }

    /**
     * Narrow a stored Number(18,0) to an Integer, PRESERVING NULL.
     *
     * ⚠ It deliberately does NOT default null to 0 — see `isChanged` for why that distinction is
     * the difference between the day-one backfill happening and the fields staying blank forever.
     *
     * @param value The stored field value.
     * @return The value as an Integer, or null when the field is null.
     */
    private static Integer intOrNull(Decimal value) {
        return (value == null) ? null : value.intValue();
    }
}
