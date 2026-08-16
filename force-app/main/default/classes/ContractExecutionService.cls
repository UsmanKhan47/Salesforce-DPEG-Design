/**
 * PSA execution handoff (called from ContractReviewTrigger, after update). When a
 * Contract Review's Negotiation_Status__c just became 'Executed':
 *
 *   1. Stamps the parent Opportunity: Contract_Signed__c, Contract_Executed_Date__c
 *      (Day 0), Deal_Status__c = 'Contract Signed'. The deal stays at the coarse
 *      'Under Contract (PSA)' stage; Deal_Status marks it executed / about to close.
 *   2. Notifies Transactions_Team + Investor_Relations (PSA executed) and
 *      Due_Diligence (Danish: DD materials available once the contract is signed).
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
 * so one `Executed` event now means two different things:
 *
 *   ACQUISITION  (Opportunity__c set)   -> stamp the Opportunity (Contract Signed, Day 0) + notify
 *   DISPOSITION  (Disposition__c set)   -> move Disposition__c.Disposition_Stage__c to 'Closing'
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
 */
public with sharing class ContractExecutionService {

    @TestVisible private static final String EXECUTED = 'Executed';

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
            Boolean justExecuted = cr.Negotiation_Status__c == EXECUTED
                && (prior == null || prior.Negotiation_Status__c != EXECUTED);
            if (!justExecuted) {
                continue;
            }
            // Two independent `if`s, never if/else — see the discriminator note in the class
            // header. A row with both parents runs both arms; a row with neither runs neither.
            if (cr.Opportunity__c != null) {
                executedOppIds.add(cr.Opportunity__c);
            }
            if (cr.Disposition__c != null) {
                executedDispositionIds.add(cr.Disposition__c);
            }
        }

        stampOpportunities(executedOppIds);
        advanceDispositionsToClosing(executedDispositionIds);
    }

    /**
     * The ACQUISITION arm — unchanged behaviour, extracted from handleExecution in Tranche 3C so
     * the two sides are separately readable and the disposition arm cannot be short-circuited by
     * the acquisition arm's early return.
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
        }
        GroupNotifier.notify(notifications);
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
     * ── 🔴 THREE THINGS CAN BLOCK THIS WRITE, AND ONLY ONE OF THEM IS A PERMISSION ──
     * This is the D16.2 / Tranche-2-C1 decision applied deliberately. Each obstacle needs its own
     * mechanism; none of the three substitutes for another:
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

        // allOrNone = false + SYSTEM_MODE. Both are load-bearing and neither covers the other's
        // obstacle — see the header. The results are deliberately NOT inspected: there is no
        // recovery action available in an after-update trigger, and the residual is visible on the
        // records themselves.
        Database.update(stageUpdates, false, AccessLevel.SYSTEM_MODE);
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