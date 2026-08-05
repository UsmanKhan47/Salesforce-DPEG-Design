/**
 * PSA execution handoff (called from ContractReviewTrigger, after update). When a
 * Contract Review's Negotiation_Status__c just became 'Executed':
 *
 *   1. Stamps the parent Opportunity: Contract_Signed__c, Contract_Executed_Date__c
 *      (Day 0), Deal_Status__c = 'Contract Signed'. The deal stays at the coarse
 *      'PSA' stage; Deal_Status marks it executed / about to close.
 *   2. Creates the Transaction__c (idempotent - never a second one per deal) with
 *      Contract_Executed_Date__c set, which ARMS the existing Transaction_Task_Fanout
 *      flow -> TaskFanoutService 75-task Day-0 checklist untouched.
 *   3. Notifies Transactions_Team + Investor_Relations (PSA executed) and
 *      Due_Diligence (Danish: DD materials available once the contract is signed).
 */
public with sharing class ContractExecutionService {

    @TestVisible private static final String EXECUTED = 'Executed';

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

        // Idempotency: a deal that already has a Transaction is not handed off twice.
        Set<Id> alreadyHandedOff = new Set<Id>();
        for (Transaction__c t : TransactionSelector.selectByOpportunityIds(executedOppIds)) {
            alreadyHandedOff.add(t.Opportunity__c);
        }

        Datetime dayZero = Datetime.now();
        List<Opportunity> oppUpdates = new List<Opportunity>();
        List<Transaction__c> transToInsert = new List<Transaction__c>();
        List<Opportunity> opps = OpportunitySelector.selectExecutionHandoffByIds(executedOppIds);
        for (Opportunity o : opps) {
            Opportunity stamp = new Opportunity(
                Id = o.Id,
                Contract_Signed__c = true,
                Deal_Status__c = 'Contract Signed'
            );
            if (o.Contract_Executed_Date__c == null) {
                stamp.Contract_Executed_Date__c = dayZero;
            }
            oppUpdates.add(stamp);

            if (!alreadyHandedOff.contains(o.Id)) {
                transToInsert.add(new Transaction__c(
                    Opportunity__c = o.Id,
                    Property__c = o.Property__c,
                    Contract_Value__c = o.Primary_Contract__r != null ? o.Primary_Contract__r.Contract_Value__c : null,
                    Earnest_Money__c = o.Primary_LOI__r != null ? o.Primary_LOI__r.Earnest_Money__c : null,
                    Contract_Executed_Date__c = dayZero.date(), // arms the Day-0 task fan-out
                    Status__c = 'Active',
                    Stage__c = 'Open Contract',
                    Target_Close_Date__c = Date.today().addDays(60)
                ));
            }
        }
        // 🔴 EXPLICIT SYSTEM MODE — THE PROCESS OPENS THE TRANSACTION, NOT THE USER.
        // This runs as whoever executed the contract, i.e. the DEAL DRIVER, and the deal driver is
        // deliberately READ-ONLY on Transaction__c: DPEG Junior Analyst PSG grants Read + View All
        // with Create = false, and his profile (Minimum Access) grants nothing on the object at all
        // (measured 2026-08-05). A bare `insert` therefore threw
        //   System.TypeException: DML operation INSERT not allowed on Transaction__c
        // and took the whole contract execution with it.
        //
        // Granting the deal driver Create on Transaction__c was rejected as the fix: it would let
        // him create transactions at will, permanently, to satisfy one automated handoff. Handing
        // the deal to the Transactions team is a consequence of the process, so the requirement is
        // stated at the DML instead. Same reasoning and same remedy as ApprovalAuditService.
        //
        // The Opportunity stamp gets the same treatment for consistency, not because it fails
        // today — the deal driver does hold Edit on Opportunity. Leaving one of the two writes
        // user-mode would make this method's behaviour depend on which persona happens to execute
        // a contract, which is precisely the class of surprise this comment exists to prevent.
        Database.update(oppUpdates, true, AccessLevel.SYSTEM_MODE);
        if (!transToInsert.isEmpty()) {
            Database.insert(transToInsert, true, AccessLevel.SYSTEM_MODE);
        }

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