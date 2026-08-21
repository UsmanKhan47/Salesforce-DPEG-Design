/**
 * PSA execution handoff (called from ContractReviewTrigger, after update). When a
 * Contract Review's Negotiation_Status__c just reached ITS OWN TERMINAL:
 *
 *   ACQUISITION (Opportunity__c set)  terminal 'Executed'   ← unchanged
 *   DISPOSITION (Disposition__c set)  terminal 'Signed'     ← 2026-08-21, user harmonisation
 *
 * ⚠ THIS SENTENCE READ "just became 'Executed'" UNTIL 2026-08-21. There is no longer a single
 * terminal: the user removed 'Executed' from the `Disposition_PSA` record type. See
 * ACQUISITION_TERMINAL / DISPOSITION_TERMINAL for the measurement, the reason the sell-side handoff
 * was silently unreachable in between, and why repointing one shared constant would have shifted
 * every deadline in every acquisition transaction.
 *
 * On that arrival:
 *
 *   1. Stamps the parent Opportunity: Contract_Signed__c, Contract_Executed_Date__c
 *      (Day 0), Deal_Status__c = 'Contract Signed'. The deal stays at the coarse
 *      'Under Contract (PSA)' stage; Deal_Status marks it executed / about to close.
 *   2. Notifies Transactions_Team + Investor_Relations (PSA executed), Due_Diligence
 *      (Danish: DD materials available once the contract is signed) and — since tranche 2,
 *      2026-08-16, FSD §23 gap #7 — Acquisitions_Team. THAT IS FOUR PER DEAL, NOT THREE;
 *      see the CPU arithmetic below before adding a fifth.
 *   3. Opens the IR `Offering__c` shell (FSD Tranche 1, 2026-08-16) via
 *      OfferingService.ensureOnPsaExecuted — idempotent, allOrNone = false, SYSTEM_MODE, and
 *      ACQUISITION-ONLY BY CONSTRUCTION because the call sits inside stampOpportunities, whose
 *      Id set can only hold non-null Opportunity__c parents. It adds NO notification (IR is
 *      already told in step 2) and NO Primary_Offering__c stamp. See OfferingService's header.
 *
 * ⚠ THIS CLASS NOW HAS TWO ENTRY POINTS ON TWO DIFFERENT TRIGGERS, AND THEY DO DIFFERENT THINGS.
 *
 *   handleExecution                (ContractReviewTrigger)      contract EXECUTED -> stamp + notify
 *   openTransactionsOnAboutToClose (OpportunityReviewTrigger)   stage ABOUT TO CLOSE -> Transaction
 *
 * Creating the Transaction MOVED out of handleExecution on 2026-08-05 (user decision): the
 * Transactions team now picks a deal up when it is genuinely about to close, not at signature.
 * handleExecution still stamps Day 0 — and openTransactionsOnAboutToClose READS THAT STAMP BACK to
 * date the 75-task checklist, so the two remain coupled even though they no longer run together.
 * Do not re-add Transaction creation to handleExecution.
 *
 * ── 🔴 handleExecution NOW HAS TWO ARMS, ONE PER SIDE OF THE HOUSE (Tranche 3C, 2026-08-09) ──
 * `Contract_Review__c` gained an `Acquisition_PSA` / `Disposition_PSA` record-type pair (D6/D16.3),
 * so one execution event meant two different things:
 *
 *   ACQUISITION  (Opportunity__c set)   -> stamp the Opportunity (Contract Signed, Day 0) + notify
 *   DISPOSITION  (Disposition__c set)   -> move Disposition__c.Disposition_Stage__c to 'Closing'
 *
 * ⚠ AND SINCE 2026-08-21 IT IS NOT EVEN ONE EVENT. This block said "one `Executed` event now means
 * two different things"; the two arms now watch two DIFFERENT VALUES, so they are two events that
 * happen to share a method. The arms themselves are otherwise unchanged.
 *
 * ── 🔴 THE NOTIFICATION CPU BUDGET — READ THIS BEFORE ADDING A FIFTH RECIPIENT ──
 * `GroupNotifier`'s MEASURED cost model (its own header, measured on `usman-dpeg`
 * 2026-08-14) is **≈ 6.0 ms CPU per `send()` + 0.22 ms per RECIPIENT**, with zero SOQL and
 * zero DML per send. `stampOpportunities` sends one notification PER OPPORTUNITY PER GROUP,
 * so the count scales with the trigger chunk:
 *
 *     recipients per deal      3  ->  4         (tranche 2, gap #7)
 *     sends at a 200-row chunk 600 -> 800
 *     synchronous CPU          ~3.7 s -> ~5.0 s   against a 10 s limit
 *
 * ⚠ THAT IS A PRE-EXISTING EXPOSURE WIDENED BY ~25%, NOT A NEW ONE — and it is spent BEFORE
 * the rest of the transaction (the stamp, the Offering shell, every downstream trigger). A
 * 200-row `Contract_Review__c` chunk all flipping to `Executed` at once is a data-load
 * scenario rather than an ordinary day, which is why gap #7 was built as asked rather than
 * deferred. But the headroom is now roughly half, and a FIFTH recipient takes it to ~6.3 s.
 * 🔴 Anyone adding one should either bound the chunk or move the notification batch
 * asynchronous — and must not do it on the assumption that this is still cheap.
 *
 * ⚠ Do NOT "optimise" this by calling `GroupNotifier.send()` inside the loop. That is the
 * exact defect the batching comment inside `stampOpportunities` records: it re-enters an
 * already-bulkified method once per record and costs 3 fresh QUERIES each time (1,800 for a
 * 200-record chunk against a 100-query limit). `notify()` is O(1) in queries for any batch
 * size, so a fourth recipient adds CPU and NOT A SINGLE QUERY.
 *
 * ⚠ THE BRANCH IS ADDITIVE, NOT DEFENSIVE, AND THE DIFFERENCE MATTERS TO ANYONE PRICING IT. An
 * earlier brief warned that an executed SALE would mint a phantom acquisition `Transaction__c`.
 * THAT RISK NO LONGER EXISTS and nothing here guards against it: Transaction creation left this
 * method on 2026-08-05 for `openTransactionsOnAboutToClose`, which keys on
 * `Opportunity.StageName = 'About to Close'` — a stage a disposition Contract Review can never
 * reach — and the acquisition arm below has ALWAYS dropped a Contract Review with a null
 * `Opportunity__c`. So the disposition arm adds behaviour; it prevents nothing.
 *
 * 🔴 THE DISCRIMINATOR IS THE PARENT LOOKUP, NOT THE RECORD TYPE, AND THAT IS DELIBERATE. Each arm
 * keys on its own lookup being non-null. Three reasons, in order of force:
 *   1. It is what `Contract_Review__c.Disposition__c`'s own field metadata mandates — "this lookup,
 *      NOT the record type, is the discriminator anything outside the record page should test".
 *   2. It WORKS DURING THE MIGRATION WINDOW. Between the record-type deploy and post-deploy gate
 *      T-B every row sits on Master, so a record-type test would classify every disposition PSA as
 *      neither arm and silently do nothing at all.
 *   3. The two arms are then independent by construction rather than by an else-branch: a
 *      malformed row carrying BOTH parents runs both arms, and a row carrying neither runs
 *      neither. An if/else on record type would have had to invent an answer for both cases.
 *   4. ➕ ADDED 2026-08-21, AND IT IS NOW THE DECISIVE ONE. The TERMINAL is per side too, and a
 *      lookup-keyed arm paired with a record-type-keyed terminal could DISAGREE about a row — on
 *      Master, or on a row carrying both parents. The disagreement is silent: no exception, just a
 *      handoff that does nothing or stamps the wrong parent. Deriving arm and terminal from the
 *      SAME expression makes that unrepresentable, which is why the terminal test now sits inside
 *      each arm's own `if` rather than in a shared pre-filter above them.
 */
public with sharing class ContractExecutionService {

    /**
     * The notification batch the last `stampOpportunities` built, in build order — a
     * `lastRun*` test seam of the house shape (`ExtractAddressQueueable.lastRunQueryCount`,
     * `EmailThreadAdopterService.lastRunFailureCodes`, `DealFolderQueueable.lastRunChainedIds`).
     *
     * 🔴 IT EXISTS BECAUSE THE NOTIFICATION SET IS OTHERWISE UNFALSIFIABLE FROM A TEST.
     * Custom notifications cannot be queried in Apex, and `GroupNotifier.sentCount` counts
     * only SUCCESSFUL sends — which is zero here, because group MEMBERSHIP is not deployable
     * metadata, so `Acquisitions_Team` and its siblings resolve to no users in a test org.
     * An assertion on `sentCount` would therefore be VACUOUS: it would read `0` whether this
     * method sent three notifications, four, or none at all. Asserting the batch this method
     * BUILT is the only non-vacuous pin available without inserting `GroupMember` rows under
     * `System.runAs` (a setup-object mixed-DML hop for a read-only fact).
     *
     * ⚠ In-transaction only; it does not survive the transaction and is not for monitoring.
     */
    @TestVisible
    private static List<GroupNotifier.Request> lastRunNotifications = new List<GroupNotifier.Request>();

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE PSA TERMINAL IS PER SIDE OF THE HOUSE AS OF 2026-08-21. THERE IS NO LONGER ONE.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * ⚠ RETRACTED, verbatim: `@TestVisible private static final String EXECUTED = 'Executed';` —
     * one constant, tested once, feeding both arms.
     *
     * The user harmonised `Contract_Review__c.Negotiation_Status__c` on the `Disposition_PSA`
     * record type. LIVE, measured via the UI API on 2026-08-21 (see the note on the channel below):
     *
     *   Acquisition_PSA   Draft (default) | Negotiation | Signed | Executed      ← UNCHANGED
     *   Disposition_PSA   Initial Draft (default) | Negotiation | Signed         ← 'Executed' GONE
     *
     * 🔴 SO THE SELL-SIDE HANDOFF WAS SILENTLY UNREACHABLE BETWEEN THAT CHANGE AND THIS ONE. A
     * disposition PSA can no longer HOLD 'Executed' — `Negotiation_Status__c` is a restricted
     * picklist and Apex DML enforces the record type's subset (measured three separate ways; see
     * RecordStageAdvanceService's class header) — so `justExecuted` could never be true on a sale.
     * `Disposition_Stage__c` would have stayed on 'PSA' forever, with no error and no test failure
     * on the acquisition side. That is the failure mode this split exists to close.
     *
     * ── 🔴 WHY THE DISCRIMINATOR IS THE PARENT LOOKUP AND NOT THE RECORD TYPE ────
     * The class header already argues the lookup for the two ARMS (field metadata mandates it; it
     * survives the Master-row migration window; it keeps the arms independent rather than
     * else-branched). Those three transfer here unchanged. A FOURTH reason is specific to the
     * TERMINAL and is the decisive one:
     *
     *   🔴 A LOOKUP-KEYED ARM PAIRED WITH A RECORD-TYPE-KEYED TERMINAL CAN DISAGREE, AND THE
     *   DISAGREEMENT IS SILENT. A row on Master (or a malformed row carrying BOTH parents) would be
     *   classified one way for "which terminal counts?" and the other way for "which arm runs?".
     *   The result is a row that either does nothing at all or stamps the wrong parent, with no
     *   exception to trace. Deriving BOTH from the same expression makes that class of bug
     *   unrepresentable — the terminal test now lives INSIDE each arm's own `if`, so an arm cannot
     *   run against a terminal it did not choose.
     *
     * ⚠ THIS IS NOT THE SAME REASONING AS THE LOI PRICE RULE, though it reaches the same answer.
     * `Final_Price_Required_Before_Executed` picked `NOT(ISBLANK(Disposition__c))` because a
     * VALIDATION RULE cannot scope on a record type without excluding Master rows and without
     * breaking on a record-type rename. Neither of those applies to Apex. The argument here is
     * arm/terminal agreement; do not cite one as precedent for the other.
     *
     * ⚠ ON THE MEASUREMENT CHANNEL, because the obvious ones are worthless here: Metadata API
     * retrieve, Tooling `RecordType.Metadata` and `PicklistValueInfo` all return EMPTY for every
     * record type on this object, so their silence proves nothing. The only channel that reports
     * record-type-scoped picklist values is the UI API:
     *   /services/data/v67.0/ui-api/object-info/Contract_Review__c/picklist-values/<rtId>
     */
    @TestVisible private static final String ACQUISITION_TERMINAL = 'Executed';

    /**
     * The sell-side PSA terminal, 2026-08-21. 'Signed' is the LAST value on `Disposition_PSA`.
     *
     * 🔴 'Signed' IS ALSO ON Acquisition_PSA, AND IT IS NOT TERMINAL THERE — it is the immediate
     * PREDECESSOR of 'Executed' (CONTRACT_REVIEW_ACQUISITION_NEXT_STAGE: Draft -> Negotiation ->
     * Signed -> Executed). THE TWO TERMINALS ARE NO LONGER DISJOINT VALUES, which is exactly why a
     * single shared predicate cannot express this and why repointing one constant globally would be
     * a live acquisition defect rather than a refactor:
     *
     *   Every acquisition PSA passes THROUGH 'Signed' on its way to 'Executed'. A global repoint
     *   would fire the Day-0 stamp, the four notifications and the Offering shell ONE HOP EARLY —
     *   at signature instead of at execution — and `Contract_Executed_Date__c` dates the entire
     *   ~75-task Day-0 checklist by offset. Every deadline in every acquisition transaction would
     *   shift. Pinned by executingAnAcquisitionPsaThroughSignedDoesNotFireTheHandoff.
     *
     * ⚠ Do not "simplify" the two constants back into one, and do not add 'Signed' to the
     * acquisition side "for symmetry".
     */
    @TestVisible private static final String DISPOSITION_TERMINAL = 'Signed';

    /** The Opportunity stage that opens the transaction. */
    @TestVisible private static final String ABOUT_TO_CLOSE = 'About to Close';

    /**
     * The Disposition stage an executed sell-side PSA advances the sale to (Tranche 3C).
     *
     * ⚠ It is `Disposition__c.Disposition_Stage__c`, NOT `Contract_Review__c.Stage__c`. The latter
     * is a DERIVED PROJECTION recomputed by the `Contract_Review_Stage_Sync` before-save flow on
     * every save, so a direct write to it COMMITS AND IS SILENTLY DISCARDED (measured 2026-08-05 on
     * CTR-0000). Nothing in this class writes it.
     */
    @TestVisible private static final String DISPOSITION_CLOSING = 'Closing';

    /**
     * Opens the Transaction__c (and, through it, the Day-0 task checklist) when a deal ENTERS the
     * 'About to Close' stage. Called from OpportunityReviewTriggerHandler, after insert/update.
     *
     * ── WHY HERE AND NOT AT CONTRACT EXECUTION (moved 2026-08-05, user decision) ──
     * handleExecution used to create the Transaction the moment a Contract Review became
     * 'Executed'. The trigger point is now the OPPORTUNITY stage, so the Transactions team picks a
     * deal up when it is genuinely about to close rather than at signature. handleExecution still
     * stamps Contract_Signed__c / Contract_Executed_Date__c and still notifies the three teams — it
     * simply no longer opens the transaction. Do not re-add creation there: two creators would race
     * on the same idempotency read within one transaction.
     *
     * ── 🔴 DAY 0 IS THE CONTRACT EXECUTION DATE, NOT TODAY ──
     * Transaction__c.Contract_Executed_Date__c ARMS the Transaction_Task_Fanout flow, and every one
     * of the ~75 checklist tasks is dated by offset from it. By the time a deal reaches About to
     * Close the contract may have been executed weeks earlier, so dating the checklist "now" would
     * silently shift every deadline. It therefore reads Opportunity.Contract_Executed_Date__c and
     * falls back to today ONLY when the deal reached this stage without an executed contract —
     * which is possible, because 'About to Close' is an explicit-target stage the deal driver can
     * set directly (StageAdvanceService.ALLOWED_EXPLICIT_TARGETS).
     *
     * ── ACCESS ──
     * The DML is EXPLICIT SYSTEM MODE and that is load-bearing, not defensive. This runs as the deal
     * driver, who is deliberately READ-ONLY on Transaction__c — Create = false on the permission set
     * and no grant at all on the Minimum Access profile (measured 2026-08-05). A bare insert throws
     * System.TypeException: DML operation INSERT not allowed on Transaction__c. Granting the deal
     * driver Create was rejected: the transaction is opened BY THE PROCESS, and he must be able to
     * view one without ever being able to make one.
     *
     * Idempotent: a deal that already has a Transaction never gets a second one, so re-entering the
     * stage is a no-op.
     *
     * @param newOpps Trigger.new
     * @param oldMap  Trigger.oldMap on update; null on insert.
     */
    public static void openTransactionsOnAboutToClose(
            List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        Set<Id> entering = new Set<Id>();
        for (Opportunity o : newOpps) {
            Opportunity prior = (oldMap == null) ? null : oldMap.get(o.Id);
            Boolean justEntered = o.StageName == ABOUT_TO_CLOSE
                && (prior == null || prior.StageName != ABOUT_TO_CLOSE);
            if (justEntered) {
                entering.add(o.Id);
            }
        }
        if (entering.isEmpty()) {
            return;
        }

        // Idempotency: a deal that already has a Transaction is not handed off twice.
        Set<Id> alreadyHandedOff = new Set<Id>();
        for (Transaction__c t : TransactionSelector.selectByOpportunityIds(entering)) {
            alreadyHandedOff.add(t.Opportunity__c);
        }

        List<Transaction__c> transToInsert = new List<Transaction__c>();
        for (Opportunity o : OpportunitySelector.selectExecutionHandoffByIds(entering)) {
            if (alreadyHandedOff.contains(o.Id)) {
                continue;
            }
            Date dayZero = (o.Contract_Executed_Date__c == null)
                ? Date.today()
                : o.Contract_Executed_Date__c.date();
            transToInsert.add(new Transaction__c(
                Opportunity__c = o.Id,
                Property__c = o.Property__c,
                Contract_Value__c = o.Primary_Contract__r != null ? o.Primary_Contract__r.Contract_Value__c : null,
                Earnest_Money__c = o.Primary_LOI__r != null ? o.Primary_LOI__r.Earnest_Money__c : null,
                Contract_Executed_Date__c = dayZero, // arms the Day-0 task fan-out
                Status__c = 'Active',
                Stage__c = 'Open Contract',
                Target_Close_Date__c = Date.today().addDays(60)
            ));
        }
        if (!transToInsert.isEmpty()) {
            Database.insert(transToInsert, true, AccessLevel.SYSTEM_MODE);
        }
    }

    /**
     * PSA execution handoff, both sides of the house.
     *
     * ⚠ THE TWO ARMS ARE INDEPENDENTLY GUARDED, AND THE `executedOppIds.isEmpty()` EARLY RETURN
     * THAT USED TO SIT HERE HAS MOVED INSIDE THE ACQUISITION ARM. Left where it was, an
     * all-disposition trigger chunk (zero Opportunity parents — the ordinary case for a sale)
     * would have returned before the disposition arm ever ran, and the whole feature would have
     * been dead while every acquisition test stayed green. That is the single easiest way to get
     * this change wrong.
     *
     * @param newCrs Trigger.new
     * @param oldMap Trigger.oldMap on update; null on insert.
     */
    public static void handleExecution(List<Contract_Review__c> newCrs, Map<Id, Contract_Review__c> oldMap) {
        Set<Id> executedOppIds = new Set<Id>();
        Set<Id> executedDispositionIds = new Set<Id>();
        for (Contract_Review__c cr : newCrs) {
            Contract_Review__c prior = (oldMap == null) ? null : oldMap.get(cr.Id);
            // ⚠ THE TERMINAL TEST MOVED INSIDE THE TWO ARMS ON 2026-08-21 AND THE SHARED
            // `justExecuted` / `if (!justExecuted) continue;` PRE-FILTER IS GONE. It read:
            //     Boolean justExecuted = cr.Negotiation_Status__c == EXECUTED
            //         && (prior == null || prior.Negotiation_Status__c != EXECUTED);
            //     if (!justExecuted) { continue; }
            // One terminal fed both arms because both record types ended at 'Executed'. The user
            // harmonised Disposition_PSA to end at 'Signed', so there are now two terminals and
            // they are NOT disjoint values — 'Signed' is a mid-sequence stage on the acquisition
            // side. A shared predicate can no longer answer "did this just reach ITS end?".
            // See DISPOSITION_TERMINAL for what a global repoint would have cost.
            //
            // Two independent `if`s, never if/else — see the discriminator note in the class
            // header. A row with both parents runs both arms; a row with neither runs neither.
            // That property is UNCHANGED: each arm still tests only its own lookup, and now also
            // its own terminal, so the arm and the terminal cannot disagree about a row.
            if (cr.Opportunity__c != null && justReached(cr, prior, ACQUISITION_TERMINAL)) {
                executedOppIds.add(cr.Opportunity__c);
            }
            if (cr.Disposition__c != null && justReached(cr, prior, DISPOSITION_TERMINAL)) {
                executedDispositionIds.add(cr.Disposition__c);
            }
        }

        stampOpportunities(executedOppIds);
        advanceDispositionsToClosing(executedDispositionIds);
    }

    /**
     * True when this save is the EDGE onto `terminal` — the value is there now and was not before.
     *
     * Extracted 2026-08-21 so the two arms share the edge-detection SHAPE while each supplies its
     * own terminal. Keeping one expression is the point: the acquisition and disposition arms must
     * differ ONLY in which value they watch for, never in how they decide "just arrived".
     *
     * 🔴 EDGE, NOT LEVEL, AND THAT IS LOAD-BEARING ON BOTH SIDES. `prior == null` (an INSERT)
     * counts as an arrival, which is how a row created directly at its terminal is handled; every
     * other save must show a CHANGE. Without the `prior` half, any later edit to an already-executed
     * PSA — a version bump, a ball-in-court change, a re-parent — would re-stamp Day 0 and re-send
     * four notifications on the acquisition side, and would re-drive an already-Closing sale
     * backwards through `advanceDispositionsToClosing` on the disposition side.
     *
     * @param cr       the row as saved
     * @param prior    the row as it was, or null on insert
     * @param terminal the terminal for THIS row's side of the house
     */
    private static Boolean justReached(
            Contract_Review__c cr, Contract_Review__c prior, String terminal) {
        return cr.Negotiation_Status__c == terminal
            && (prior == null || prior.Negotiation_Status__c != terminal);
    }

    /**
     * The ACQUISITION arm — extracted from handleExecution in Tranche 3C so the two sides are
     * separately readable and the disposition arm cannot be short-circuited by the acquisition
     * arm's early return.
     *
     * ⚠ "UNCHANGED BEHAVIOUR" WAS TRUE UNTIL 2026-08-16 AND IS NO LONGER — amended in place rather
     * than left standing. This method now also opens the IR `Offering__c` shell, as its LAST
     * statement. That is FSD Tranche 1 Item 1, and the placement is the whole acquisition-only
     * mechanism: see the note at the call and `OfferingService`'s class header.
     *
     * ⚠ THE `Executed_PSA_Before_Contract_Date` VALIDATION RULE (added in the same tranche) MEETS
     * THIS METHOD'S `Database.update(oppUpdates, true, SYSTEM_MODE)`, and `AccessLevel.SYSTEM_MODE`
     * bypasses CRUD and FLS but **NOT validation rules**. The rule is written to be inert here: it
     * fires only when `Primary_Contract__r.Negotiation_Status__c <> 'Executed'` AND
     * `Primary_Contract__c` is non-blank, and by the time this runs the Contract Review row is
     * already written with `Executed` inside the same transaction. There is also no catch anywhere
     * on this path, so a block would propagate out of the trigger and — through
     * `RecordStageAdvanceController`'s fixed generic message — reach the user as "this change could
     * not be saved" with no clue why. `ContractExecutionServiceTest` staying green IS the proof
     * that the cross-object rule sees the in-transaction status (post-deploy gate G5); do not
     * weaken those tests.
     *
     * @param executedOppIds Opportunities whose PSA just became Executed; empty-safe.
     */
    private static void stampOpportunities(Set<Id> executedOppIds) {
        if (executedOppIds.isEmpty()) {
            return;
        }

        Datetime dayZero = Datetime.now();
        List<Opportunity> oppUpdates = new List<Opportunity>();
        List<Opportunity> opps = OpportunitySelector.selectExecutionHandoffByIds(executedOppIds);
        for (Opportunity o : opps) {
            Opportunity stamp = new Opportunity(
                Id = o.Id,
                Contract_Signed__c = true,
                Deal_Status__c = 'Contract Signed'
            );
            if (o.Contract_Executed_Date__c == null) {
                // Day 0. This is now the ONLY place it is stamped, and openTransactionsOnAboutToClose
                // reads it back to date the checklist — so this assignment outlives the execution
                // step and must not be removed with it.
                stamp.Contract_Executed_Date__c = dayZero;
            }
            oppUpdates.add(stamp);
        }
        // SYSTEM MODE: this runs as whoever executed the contract, and the write must not depend on
        // which persona that is. See openTransactionsOnAboutToClose for the full reasoning — it is
        // the same one, and there it is load-bearing rather than merely defensive.
        Database.update(oppUpdates, true, AccessLevel.SYSTEM_MODE);

        // Build every notification first, then hand the whole batch to
        // GroupNotifier.notify() ONCE. GroupNotifier.send() is a single-request
        // wrapper around notify(); calling it inside this loop re-entered an
        // already-bulkified method once per record and cost 3 fresh queries each
        // time - 9 per Opportunity, 1,800 for a 200-record trigger chunk against
        // a 100-query limit. Batched, the identical 600 notifications cost 3
        // queries: notify() is O(1) in queries regardless of request count.
        List<GroupNotifier.Request> notifications = new List<GroupNotifier.Request>();
        for (Opportunity o : opps) {
            notifications.add(buildNotification('Transactions_Team',
                'PSA executed - transaction opened',
                o.Name + ': Day 0. The closing checklist has been fanned out.', o.Id));
            notifications.add(buildNotification('Investor_Relations',
                'PSA executed',
                o.Name + ': contract signed - IR phase begins.', o.Id));
            notifications.add(buildNotification('Due_Diligence',
                'Due diligence materials available',
                o.Name + ': the contract is signed - DD materials are ready for review.', o.Id));
            // FSD §23 gap #7 (tranche 2, 2026-08-16). The team that WORKED the deal was the
            // only one not told it had executed. See the CPU arithmetic in the class header.
            notifications.add(buildNotification('Acquisitions_Team',
                'PSA executed',
                o.Name + ': the PSA is executed.', o.Id));
        }
        lastRunNotifications = notifications;
        GroupNotifier.notify(notifications);

        // ── THE IR OFFERING SHELL (FSD Tranche 1, Item 1 — FSD §9 Conversion 3) ──
        // 🔴 IT IS HERE, INSIDE stampOpportunities, AND NOWHERE ELSE — that placement is what makes
        // it ACQUISITION-ONLY STRUCTURALLY. `executedOppIds` can only ever contain non-null
        // Contract_Review__c.Opportunity__c parents (see handleExecution's two independent `if`s), so
        // a sell-side PSA never reaches this line and NO record-type test and NO new guard is needed.
        // Same discriminator, and the same migration-window reason, as the class header gives.
        //
        // ⚠ IT RUNS LAST, DELIBERATELY. Everything above it is deployed, live behaviour; running the
        // new insert after it means the new code cannot precede or endanger the stamp or the three
        // notifications. Nothing an observer sees depends on the order — the insert and the update
        // commit in one transaction — so this costs nothing and buys blast-radius containment.
        //
        // ⚠ NO SECOND NOTIFICATION. IR is already told, three lines above, at this exact moment.
        // ⚠ NO Primary_Offering__c STAMP. The field does not exist and must not be added for
        // symmetry with Primary_LOI__c — see OfferingService's header §6.
        // ⚠ AND DO NOT RE-ADD TRANSACTION CREATION HERE while adding to this method; it moved to
        // openTransactionsOnAboutToClose on 2026-08-05 and the class header says why.
        //
        // Budget: +1 SOQL / +1 DML per trigger chunk, CONSTANT in deal count. A chunk executing no
        // acquisition PSA never reaches this method at all (the early return above).
        OfferingService.ensureOnPsaExecuted(executedOppIds);
    }

    /**
     * The DISPOSITION arm (Tranche 3C, 2026-08-09) — an executed sell-side PSA moves the sale to
     * `Closing`.
     *
     * 🔴 THIS IS THE FIRST MACHINE WRITER OF `Disposition__c.Disposition_Stage__c` IN THE
     * APPLICATION. Two deployed artifacts assert in their own XML comments that the field is
     * "written by nothing but user edits — the Path, the Details section and inline edit":
     * `objects/Disposition__c/validationRules/All_NDAs_Signed_Before_Progression` (which names
     * this change explicitly as the moment its claim expires) and
     * `.../Wire_Complete_Before_Completed`. THAT CLAIM IS NOW FALSE IN BOTH FILES and must be
     * corrected there. It is NOT corrected in this change: `objects/` was out of scope for the
     * Tranche 3C Apex build, so it is carried as a handoff rather than silently left to rot.
     *
     * ── 🔴 FOUR THINGS CAN BLOCK THIS WRITE, AND ONLY TWO OF THEM ARE PERMISSIONS ──
     * ⚠ THIS HEADING READ "THREE THINGS … ONLY ONE OF THEM IS A PERMISSION" UNTIL 2026-08-21 AND IS
     * CORRECTED IN PLACE RATHER THAN REWRITTEN — items 1-3 are unchanged and still correct. Item 4
     * was MISSING, not wrong, and the omission is the shape that cost a UAT cycle one module over
     * (`DispositionOfferTriggerHandler`, `DISP-0011`): a list of obstacles that looks exhaustive is
     * how a fourth one stays invisible.
     * This is the D16.2 / Tranche-2-C1 decision applied deliberately. Each obstacle needs its own
     * mechanism; none of the four substitutes for another:
     *
     *  1. CRUD / FLS — whoever executes a PSA (Legal, a deal driver) is not necessarily an EDITOR
     *     of `Disposition__c`. Answered by `AccessLevel.SYSTEM_MODE`, the same justification the
     *     two sibling DMLs in this class carry.
     *
     *  2. AN APPROVAL LOCK — `Disposition__c` is the entry object of THREE approval processes, all
     *     `recordEditability = AdminOnly`. 🔴 `SYSTEM_MODE` DOES NOT LIFT AN APPROVAL LOCK (measured
     *     in this repo twice: `OpportunityReviewService`'s LOI back-stamp, and Tranche 2's C1
     *     finding). Answered by `allOrNone = false` — see the trade below.
     *
     *  3. A VALIDATION RULE — `All_NDAs_Signed_Before_Progression` gates entry to `Closing` on an
     *     OFF-MARKET disposition until every non-Declined NDA is Signed. That rule is CORRECT and
     *     must keep firing here: an executed PSA does not entitle a sale to skip the release gate.
     *     Also answered by `allOrNone = false`.
     *
     *  4. 🔴 RECORD-LEVEL SHARING — ADDED 2026-08-21, AND IT IS A DIFFERENT REFUSAL FROM ITEM 1.
     *     `Disposition__c` is OWD **Private** (`InternalSharingModel = Private`, measured via
     *     Tooling `EntityDefinition` 2026-08-21) and the sale is owned by whoever created it, not by
     *     whoever executes the PSA. Item 1's `AccessLevel.SYSTEM_MODE` lifts CRUD and FLS and
     *     **never sharing** (ARCHITECTURE.md §2), so it does not reach this one.
     *     ⚠ THE READ CANNOT WARN YOU. The comment at the selector call below says an unseen
     *     disposition "is simply absent from this result … skip rather than guess" — TRUE, and it is
     *     why this never writes a WRONG row. But it is not a filter that keeps unwritable rows out
     *     of the DML, because BOTH disposition permission sets carry `viewAllRecords = true` and
     *     NEITHER carries `modifyAllRecords`. The population that can READ every sale and EDIT
     *     almost none is therefore the NORMAL case, not an edge: the read succeeds, the row reaches
     *     the update, and the update is refused. That is precisely how the sibling defect presented
     *     (`DispositionOfferTriggerHandler`, `DISP-0011` / `OFFER-0007`, measured
     *     `HasReadAccess = true, HasEditAccess = false` for the running principal).
     *     Answered by the `private without sharing ClosingStageWrites` inner class below.
     *     ⚠ NO PRODUCTION INCIDENT IS RECORDED FOR *THIS* SITE, and that is stated rather than
     *     implied. It was fixed on the strength of the sibling's measurement plus the permission-set
     *     shape above, both of which apply here unchanged. The honest version of the argument is
     *     "the same refusal is reachable here by the same mechanism", not "this broke".
     *
     * ── WHY allOrNone = false, STATED AS A TRADE RATHER THAN AS A SAFETY FEATURE ──
     * An all-or-none update would roll back THE PSA EXECUTION ITSELF — the Contract Review's
     * `Executed` status, the parent stamp, the notifications — in order to protect a stage advance.
     * The legal state is the irreplaceable half; the stage is derivable. So the write fails soft.
     *
     * 🔴 ITS RESIDUAL IS REAL AND IS NOT HARMLESS: the disposition sits at `PSA` while its Contract
     * Review reads `Executed`. Do not describe that as benign. What makes it ACCEPTABLE is that it
     * is VISIBLE — both records are on screen, they disagree, and any user can advance the stage by
     * hand once the block clears. Contrast the alternative, which is a rolled-back execution the
     * user is told nothing useful about.
     *
     * ── WHY NOT A QUEUEABLE, WHICH IS THE OTHER HALF OF THE D16.2 PATTERN ──
     * `OpportunityReviewService` defers its parent stamp to `LoiPrimaryStampQueueable` because the
     * lock is released BY THE VERY TRANSACTION doing the deferring (both approvals set
     * `finalApprovalRecordLock = false`, so the record unlocks at commit — exactly when the
     * queueable runs). 🔴 THAT REASONING DOES NOT TRANSFER HERE AND MUST NOT BE COPIED, which is
     * precisely the mistake code review W1 caught in `DispositionNdaStampQueueable`, which had
     * copied it verbatim. Here the triggering event is a Contract Review save; it releases no
     * disposition approval, so a PENDING approval OUTLIVES any queueable this transaction could
     * enqueue. Deferring would buy nothing and would cost the failure its visibility: a failed
     * `AsyncApexJob` nobody watches instead of two records that visibly disagree.
     *
     * ── WHY THE NO-CHANGE FILTER, WHICH IS THE HALF THAT IS EASY TO SKIP ──
     * Rows already at `Closing` are dropped BEFORE the DML. This is Tranche 2's C1 remedy
     * (`Flag_Changed` no-change Decision) in Apex, and it is not merely tidy: `Closing_Approval`'s
     * entry criteria IS `Disposition_Stage__c equals Closing`, so a re-executed PSA on a
     * disposition already at Closing-under-approval fires a write that CHANGES NOTHING and CAN ONLY
     * FAIL. Filtering makes the common re-execution a genuine no-op instead of a swallowed error.
     * It also makes the operation idempotent, which is the property the re-execution test pins.
     *
     * Bulk-safe and CONSTANT in the number of dispositions: ONE selector query, ONE bulk
     * `Database.update`, no SOQL or DML in a loop.
     *
     * @param executedDispositionIds Dispositions whose sell-side PSA just became Executed;
     *                               empty-safe.
     */
    private static void advanceDispositionsToClosing(Set<Id> executedDispositionIds) {
        if (executedDispositionIds.isEmpty()) {
            return;
        }

        List<Disposition__c> stageUpdates = new List<Disposition__c>();
        // A disposition the running user cannot SEE is simply absent from this result (the read is
        // SYSTEM_MODE but the selector is `with sharing`), and an absent Id is therefore never
        // written — the write is driven by what came BACK, not by what went in. That is the correct
        // direction: skip rather than guess.
        for (Disposition__c d : DispositionSelector.selectStagesByIds(executedDispositionIds)) {
            if (DISPOSITION_CLOSING.equals(d.Disposition_Stage__c)) {
                continue; // no-change filter — see the header
            }
            stageUpdates.add(new Disposition__c(
                Id = d.Id,
                Disposition_Stage__c = DISPOSITION_CLOSING
            ));
        }
        if (stageUpdates.isEmpty()) {
            return;
        }

        // allOrNone = false + SYSTEM_MODE + `without sharing`. All three are load-bearing and no one
        // of them covers another's obstacle — see the four-item list in the header.
        // ⚠ THE CLAUSE THAT USED TO END THIS COMMENT — *"the results are deliberately NOT inspected:
        // there is no recovery action available in an after-update trigger"* — IS RETRACTED IN PLACE
        // 2026-08-21. The premise holds (nothing below rethrows or retries, for exactly that
        // reason); the conclusion did not follow. "Cannot recover" is not "must not report", and an
        // un-inspected soft DML is what let the sibling handler's identical statement fail in
        // production while every surface a person can see read as success.
        recordStageWriteFailures(new ClosingStageWrites().apply(stageUpdates), stageUpdates);
    }

    /**
     * Every `Closing` stage-write failure from the most recent `advanceDispositionsToClosing` call,
     * as `<dispositionId> -> <STATUS_CODE> | <message>`. Empty on a clean run and reset at the top
     * of every `recordStageWriteFailures` call, so it describes ONE trigger chunk.
     *
     * ⚠ IT EXISTS TO BE ASSERTED ON. `ContractExecutionServiceTest`'s non-owner executor test
     * asserts it is EMPTY, so removing the sharing escape fails with the actual `StatusCode` rather
     * than with an opaque "expected Closing, was PSA".
     */
    @TestVisible
    private static List<String> lastRunStageWriteFailures = new List<String>();

    /**
     * Sends every refused row to the debug log at ERROR and to `lastRunStageWriteFailures`.
     *
     * Report, never recovery: nothing here rethrows or retries, because both would roll back the PSA
     * execution — the legal state this method is forbidden to endanger. Shape copied from
     * `DealFolderService.stampAll`.
     *
     * @param results   Parallel to `attempted`, in input order; never null.
     * @param attempted The rows handed to the DML, used only for their Ids.
     */
    private static void recordStageWriteFailures(
        List<Database.SaveResult> results,
        List<Disposition__c> attempted
    ) {
        lastRunStageWriteFailures = new List<String>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                continue;
            }
            List<Database.Error> errors = results[i].getErrors();
            String detail = errors.isEmpty()
                ? 'no error detail returned'
                : errors[0].getStatusCode() + ' | ' + errors[0].getMessage();
            lastRunStageWriteFailures.add(attempted[i].Id + ' -> ' + detail);
            System.debug(LoggingLevel.ERROR,
                'ContractExecutionService.advanceDispositionsToClosing: LOST STAGE ADVANCE on '
                + 'Disposition__c ' + attempted[i].Id + ' -> ' + detail
                + ' | the sell-side PSA reads Executed and its sale did NOT move to Closing. '
                + 'Running user: ' + UserInfo.getUserId() + '.');
        }
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE ONE STATEMENT IN THIS CLASS THAT ESCAPES SHARING. ADDED 2026-08-21.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * WHO RUNS THIS CODE: whoever saved the sell-side `Contract_Review__c` to `Executed` — Legal, a
     * transaction coordinator, a deal driver. Not, in general, the OWNER of the Disposition, which
     * is created by the acquisitions/disposition analyst who opened the sale.
     *
     * WHY THEY PREDICTABLY LACK RECORD-LEVEL EDIT ON THE TARGET: obstacle 4 in this method's header,
     * in full. In one line: `Disposition__c` is OWD Private, the object's only Edit-granting sharing
     * rule is `Disposition_Team_RW` (Acquisitions_Analyst + subordinates -> `DPEG_Acquisitions_Team`),
     * and both disposition permission sets grant `viewAllRecords` without `modifyAllRecords` — so
     * "can read every sale, can edit almost none" is the ordinary shape of a DPEG persona.
     *
     * 🔴 `AccessLevel.SYSTEM_MODE` WAS NOT SUFFICIENT AND COULD NEVER HAVE BEEN. ARCHITECTURE.md §2:
     * *"🔴 `SYSTEM_MODE` bypasses CRUD/FLS ONLY — it does NOT bypass sharing."* Obstacle 1 and
     * obstacle 4 are two different refusals that happen to sound alike when both are described as
     * "this user is not an editor of `Disposition__c`"; one is an object permission and one is a row.
     *
     * WHY THE ESCAPE IS BOUNDED TO THIS ONE WRITE: this class stays `with sharing` and its OTHER two
     * DMLs — `stampOpportunities`'s Opportunity update and the `Transaction__c` insert — do NOT use
     * it and must not be moved into it. `Opportunity` is OWD **ReadWrite** internally (measured
     * 2026-08-21), so no sharing refusal is reachable there and an escape would be an unargued
     * widening. This inner class holds ONE statement over a list `advanceDispositionsToClosing`
     * built from rows a `with sharing` selector returned, so an invisible sale is still never
     * written. ARCHITECTURE.md §2 prescribes this exact shape; repo precedents are
     * `DispositionOfferSelector.TractionReads` (read) and `NdaExpiryAlertBatch.stampMarkers` (write).
     */
    private without sharing class ClosingStageWrites {
        /**
         * @param stageUpdates Disposition shells built by `advanceDispositionsToClosing` from rows a
         *                     `with sharing` selector returned; never null, never empty.
         * @return One `Database.SaveResult` per row, in input order. The caller inspects them.
         */
        private List<Database.SaveResult> apply(List<Disposition__c> stageUpdates) {
            return Database.update(stageUpdates, false, AccessLevel.SYSTEM_MODE);
        }
    }

    /**
     * @param groupDevName Public group / queue DeveloperName.
     * @param title        Notification title.
     * @param body         Notification body.
     * @param targetId     Record the notification points at.
     * @return A populated notification request (not yet sent).
     */
    private static GroupNotifier.Request buildNotification(
        String groupDevName, String title, String body, Id targetId
    ) {
        GroupNotifier.Request r = new GroupNotifier.Request();
        r.recipientGroup = groupDevName;
        r.title = title;
        r.body = body;
        r.targetRecordId = targetId;
        return r;
    }
}