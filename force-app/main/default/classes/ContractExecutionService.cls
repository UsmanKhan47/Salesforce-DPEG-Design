/**
 * PSA execution handoff (called from ContractReviewTrigger, after update). When a
 * Contract Review's Negotiation_Status__c just became 'Executed':
 *
 *   1. Stamps the parent Opportunity: Contract_Signed__c, Contract_Executed_Date__c
 *      (Day 0), Deal_Status__c = 'Contract Signed'. The deal stays at the coarse
 *      'PSA' stage; Deal_Status marks it executed / about to close.
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
 */
public with sharing class ContractExecutionService {

    @TestVisible private static final String EXECUTED = 'Executed';

    /** The Opportunity stage that opens the transaction. */
    @TestVisible private static final String ABOUT_TO_CLOSE = 'About to Close';

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

    public static void handleExecution(List<Contract_Review__c> newCrs, Map<Id, Contract_Review__c> oldMap) {
        Set<Id> executedOppIds = new Set<Id>();
        for (Contract_Review__c cr : newCrs) {
            Contract_Review__c prior = (oldMap == null) ? null : oldMap.get(cr.Id);
            Boolean justExecuted = cr.Negotiation_Status__c == EXECUTED
                && (prior == null || prior.Negotiation_Status__c != EXECUTED);
            if (justExecuted && cr.Opportunity__c != null) {
                executedOppIds.add(cr.Opportunity__c);
            }
        }
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