/**
 * Maintains the two Opportunity flags that let a validation rule answer a question a validation
 * rule cannot ask for itself: **does this deal have a Transaction, and is it closed?**
 *
 * layer=service. No SOQL of its own (both reads go through selectors), one bulk DML, no callouts.
 *
 * ┌───────────────────────────────────────────────────────────────────────────────────────────┐
 * │ WHY THIS CLASS EXISTS AT ALL — READ THIS BEFORE CHANGING ANYTHING                          │
 * └───────────────────────────────────────────────────────────────────────────────────────────┘
 * `Transaction__c.Opportunity__c` is a child->parent LOOKUP (`relationshipName` = `Transactions`,
 * plural). A validation rule on Opportunity can traverse a lookup UP, never DOWN to a child
 * collection, and Opportunity carries no `Primary_Transaction__c` lookup — so
 * "a deal cannot be Closed Won until its transaction is closed" is NOT expressible declaratively
 * today. The state has to be CARRIED on the parent, and something has to write it. This is that
 * something.
 *
 * ── THE TWO FLAGS, AND WHY IT IS TWO AND NOT ONE ──────────────────────────────────────────────
 * The gate FAILS CLOSED (explicit user decision, 2026-09-02): a deal with NO Transaction at all
 * cannot reach `'Closed Won'`. One Checkbox cannot express that, because it cannot distinguish
 * "no transaction" from "transaction not closed" — both would read false and the rule could not
 * tell a deal that never opened one from a deal whose transaction is still open. Two Checkboxes
 * span the three real states exactly:
 *
 *   Has_Open_Transaction__c | Has_Closed_Transaction__c | meaning                | Closed Won?
 *   ------------------------|---------------------------|------------------------|-------------
 *   false                   | false                     | no Transaction at all  | 🔴 REFUSED
 *   true                    | (either)                  | at least one still open| 🔴 REFUSED
 *   false                   | true                      | every Transaction closed| 🟢 ALLOWED
 *
 * 🔴 CHECKBOXES RATHER THAN COUNTS, AND THAT IS THE SAFETY ARGUMENT, NOT A STYLE PREFERENCE.
 * A Number field is BLANK (not zero) on every record this automation has never touched, and in a
 * formula `Transaction_Count__c = 0` is FALSE when the field is blank — so a count-based rule
 * would fail OPEN for every grandfathered deal and for any record the recompute missed, silently
 * inverting the decision the user actually made. A Checkbox has no null state: its default, `false`,
 * IS the blocked state. Every failure mode of this class — a missed recompute, an undeployed field,
 * a record created before this shipped — therefore lands on REFUSE, which is what fail-closed means.
 * Do not "upgrade" these to counts for reporting value; add a separate reporting field if that is
 * wanted.
 *
 * ── WHAT COUNTS AS CLOSED ─────────────────────────────────────────────────────────────────────
 * `Transaction__c.Status__c = 'Closed'`, and NOT `Stage__c = 'Closed'`. That choice is not free
 * and is not mine: `flows/Transaction_Complete_Close` — the flow that already closes the deal when
 * the transaction closes — keys on `Status__c`, and `Transaction_Stage_Closed_Sets_Status:21-25`
 * records an explicit user decision that it must NOT be repointed onto `Stage__c`. The before-save
 * flow `Transaction_Stage_Closed_Sets_Status` keeps `Status__c` in step whenever `Stage__c` reaches
 * `Closed`, so keying on `Status__c` captures both routes; keying on `Stage__c` would MISS a
 * Transaction closed by setting `Status__c` directly, and that transaction would still close the
 * deal through the flow while this gate said the deal had no closed transaction. Two writers
 * disagreeing about the same word is exactly the defect to avoid.
 *
 * ── ORDERING: WHY THE GATE DOES NOT BLOCK THE LEGITIMATE CLOSE ────────────────────────────────
 * On the intended path the deal is closed BY the transaction closing. Within that one save:
 *   3. before-save flows      `Transaction_Stage_Closed_Sets_Status` -> Status__c = 'Closed'
 *   4. before triggers        `TransactionStageEntryService` (in-memory only)
 *   8. AFTER TRIGGERS         <- THIS CLASS. Flags land on the parent Opportunity here.
 *  13. after-save flows       `Transaction_Complete_Close` -> Opportunity.StageName='Closed Won'
 * Apex after-triggers run BEFORE after-save record-triggered flows (platform Order of Execution
 * steps 8 and 13), so by the time the flow's Opportunity update is validated the flags are already
 * committed and the rule passes. 🔴 IF THAT ORDER EVER CHANGES, OR IF THE FLOW IS CONVERTED TO A
 * BEFORE-SAVE FLOW, THE LEGITIMATE CLOSE BREAKS AND EVERY TRANSACTION CLOSE ROLLS BACK. That is
 * the single most load-bearing assumption in this file, and
 * `DealTransactionGateServiceTest.closingTheTransaction_flipsTheFlagsAndLetsTheFlowCloseTheDeal`
 * is the only thing that would catch it.
 *
 * 🔴 ── THE ONE CASE WHERE THAT INTERACTION BITES: A DEAL WITH TWO TRANSACTIONS ─────────────────
 * `Transaction_Complete_Close` closes the deal when ANY Transaction reaches `Closed`; it does not
 * look at the deal's other Transactions. So on a deal with two, closing the FIRST makes the flow
 * attempt `Closed Won` while `Has_Open_Transaction__c` is still true, the rule refuses it, and
 * because the flow runs inside the Transaction's own save the refusal returns as
 * `CANNOT_EXECUTE_FLOW_TRIGGER` and ROLLS BACK THE TRANSACTION SAVE. Someone closing a transaction
 * gets a validation error about a deal.
 *
 * ⚠ This is an existing exposure made VISIBLE, not one created here — before the rule, the same
 * flow closed the deal on the first of two transactions, which is worse and silent — and
 * `Contract_Signed_Before_Closed_Won:16-21` already records this flow's susceptibility to
 * validation rules as an accepted risk. It is rare by construction
 * (`ContractExecutionService` creates at most one Transaction per deal and is idempotent) but the
 * lookup enforces nothing. Pinned by
 * `StageApprovalGatesTest.transactionGate_closingOneOfTwoTransactions_isRefusedAndRollsBack`.
 * ⚠ The remedy, if it is ever wanted, is a filter on the FLOW, not a weakening of this service:
 * the service is right that the deal has an open transaction. Do not "fix" it by making
 * `Has_Open_Transaction__c` ignore siblings — that would put back the silent early close.
 *
 * ── COST CONTROL — THE REASON EVERY ARM IS GATED ──────────────────────────────────────────────
 * `Transaction__c` is written several times per deal creation by the Day-0 chain
 * (`TaskFanoutService` -> `TaskRollupService` -> counter writes; `ChecklistRollupService`;
 * `ChecklistFanoutService`). `TransactionTriggerHandler`'s header promises those writes cost ZERO
 * here, and that promise is what keeps the fan-out's governor budget valid. This class keeps it by
 * collecting a parent id ONLY when the save actually changed something this gate can see:
 *   - insert / undelete : always (a new row changes the parent's counts by construction)
 *   - update            : ONLY when `Opportunity__c` moved, or when the row crossed the
 *                         closed/not-closed boundary. A counter-only write collects nothing,
 *                         calls nothing, and spends nothing.
 *   - delete            : always (the row is gone; the parent must be recomputed or it is left
 *                         permanently blocked or permanently unblocked — both are wrong)
 * When ids ARE collected the recompute is ONE aggregate query + ONE flag read + ONE bulk update
 * for the whole trigger chunk, never per record. At the platform's 200-record chunk size a
 * 251-row DML costs at most 2 x (2 SOQL + 1 DML) — `ceil(rows/200)`, which is the floor for any
 * trigger-based recompute and is asserted by in-context counters in the test class.
 *
 * ── SAVEPOINTS: DELIBERATELY NONE ─────────────────────────────────────────────────────────────
 * The flag write is not a partial-success operation and must not be one. `allOrNone = true` is
 * chosen so a refused parent write ROLLS BACK THE TRANSACTION SAVE THAT CAUSED IT, loudly, rather
 * than leaving a deal whose flags disagree with its children — a silently-stale `true` is a deal
 * that can be closed with an open transaction, which is the exact defect this gate exists to
 * prevent. A savepoint would only let this class swallow that. The platform already rolls the
 * whole trigger transaction back, which is the desired behaviour.
 *
 * @see force-app/main/default/classes/TransactionTriggerHandler.cls (the only production caller)
 * @see force-app/main/default/classes/TransactionSelector.aggregateStatusCountsByOpportunityIds
 * @see force-app/main/default/classes/OpportunitySelector.selectTransactionGateFlagsByIds
 * @see force-app/main/default/classes/TestDataFactory.markTransactionClosed (the fixture helper)
 * @see agent-output/three-gaps-design-2026-09-02.md (§4.3 option T-A, §4.4, §5.3, §8.5)
 */
public with sharing class DealTransactionGateService {

    /**
     * The one `Transaction__c.Status__c` value that means "this transaction is finished".
     * See the class header for why this is `Status__c` and not `Stage__c`.
     */
    private static final String STATUS_CLOSED = 'Closed';

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // INSTRUMENTATION
    //
    // 🔴 CAPTURED INSIDE THE TRIGGER CONTEXT, ON PURPOSE. `Test.stopTest()` restores the
    // pre-test governor counters, so a `Limits.getQueries()` assertion written AFTER `stopTest`
    // measures nothing and passes vacuously — .claude/rules/bulk-test-rule.md says so in as many
    // words. The bulk tests assert on these fields instead, and they ACCUMULATE across the
    // platform's 200-record trigger chunks so a 251-row DML is measured as the two invocations it
    // really is rather than as whichever chunk happened to run last.
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /** SOQL consumed by every `recalculate` body since the last reset. */
    @TestVisible
    private static Integer lastRunQueryCount = 0;

    /** DML statements consumed by every `recalculate` body since the last reset. */
    @TestVisible
    private static Integer lastRunDmlCount = 0;

    /** How many times `recalculate` ran with a non-empty id set (i.e. trigger chunks that worked). */
    @TestVisible
    private static Integer lastRunInvocationCount = 0;

    /** Opportunities whose flags actually MOVED. A write skipped is a write not paid for. */
    @TestVisible
    private static Integer lastRunUpdatedCount = 0;

    /** Zeroes the instrumentation. Test-only; production never calls it. */
    @TestVisible
    private static void resetRunCounters() {
        lastRunQueryCount = 0;
        lastRunDmlCount = 0;
        lastRunInvocationCount = 0;
        lastRunUpdatedCount = 0;
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // TRIGGER ENTRY POINTS
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * Recomputes the gate flags for the parents of Transactions that were just SAVED — insert,
     * update or undelete.
     *
     * On insert and undelete `priorById` is null and every non-null parent is collected: a row
     * appearing changes its parent's counts by construction. On update only the two changes this
     * gate can observe collect anything (see the class header's cost-control section), and when
     * `Opportunity__c` moved BOTH the old and the new parent are collected — otherwise the deal the
     * transaction just left would keep a flag it no longer earns.
     *
     * @param rows       `Trigger.new` for the current context (null-safe).
     * @param priorById  `Trigger.oldMap` on update; null on insert and undelete.
     * @example
     * DealTransactionGateService.refreshForSavedTransactions(
     *     (List<Transaction__c>) newList, (Map<Id, Transaction__c>) oldMap);
     */
    public static void refreshForSavedTransactions(
        List<Transaction__c> rows,
        Map<Id, Transaction__c> priorById
    ) {
        recalculate(affectedParents(rows, priorById));
    }

    /**
     * Recomputes the gate flags for the parents of Transactions that were just DELETED.
     *
     * 🔴 THIS MUST RUN IN `after delete`, NOT `before delete`. The recompute counts rows in the
     * database; in a before-delete context the row being deleted is still there, so the parent
     * would be recomputed to include the transaction that is about to vanish and the flags would
     * be wrong until something else touched the deal. A deleted Transaction must leave the deal
     * neither permanently blocked nor permanently unblocked, and only the after context can do
     * that.
     *
     * @param priorRows `Trigger.old` for the delete context (null-safe).
     */
    public static void refreshForRemovedTransactions(List<Transaction__c> priorRows) {
        Set<Id> parentIds = new Set<Id>();
        if (priorRows != null) {
            for (Transaction__c prior : priorRows) {
                if (prior.Opportunity__c != null) {
                    parentIds.add(prior.Opportunity__c);
                }
            }
        }
        recalculate(parentIds);
    }

    /**
     * The change gate. Pure in-memory: no SOQL, no DML, no describes — so a Transaction save that
     * this gate does not care about (every counter write from the Day-0 chain) leaves here having
     * spent nothing at all.
     *
     * @param rows      `Trigger.new`.
     * @param priorById `Trigger.oldMap`, or null on insert/undelete.
     * @return The parent Opportunity ids whose flags may have moved; never null.
     */
    @TestVisible
    private static Set<Id> affectedParents(
        List<Transaction__c> rows,
        Map<Id, Transaction__c> priorById
    ) {
        Set<Id> parentIds = new Set<Id>();
        if (rows == null || rows.isEmpty()) {
            return parentIds;
        }
        for (Transaction__c row : rows) {
            Transaction__c prior = (priorById == null) ? null : priorById.get(row.Id);

            if (prior == null) {
                // Insert or undelete: a row that did not exist a moment ago always moves its
                // parent's counts.
                if (row.Opportunity__c != null) {
                    parentIds.add(row.Opportunity__c);
                }
                continue;
            }

            Boolean parentMoved = prior.Opportunity__c != row.Opportunity__c;
            Boolean closednessMoved = isClosed(prior) != isClosed(row);
            if (!parentMoved && !closednessMoved) {
                // The cost control the whole design rests on. Counter writes, stage moves that do
                // not reach Closed, checklist rollups — all leave here.
                continue;
            }
            if (row.Opportunity__c != null) {
                parentIds.add(row.Opportunity__c);
            }
            if (prior.Opportunity__c != null) {
                // Re-parenting: the deal it LEFT must be recomputed too, or it keeps a flag it no
                // longer earns and stays closable for ever.
                parentIds.add(prior.Opportunity__c);
            }
        }
        return parentIds;
    }

    /**
     * `Status__c = 'Closed'` and nothing else. A null status is NOT closed, which is the correct
     * reading: a Transaction with no status has not finished.
     *
     * @param row The Transaction to classify.
     * @return true when this transaction counts as closed.
     */
    private static Boolean isClosed(Transaction__c row) {
        return STATUS_CLOSED.equals(row.Status__c);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // THE RECOMPUTE
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * Recomputes `Has_Open_Transaction__c` / `Has_Closed_Transaction__c` from the CURRENT database
     * state for the supplied deals and writes back only those whose flags actually moved.
     *
     * Public because it is also the BACKFILL entry point. Fail-closed makes every deal that
     * already owns a closed Transaction unclosable until its flags are populated, and the flags do
     * not populate themselves — nothing re-saves an old Transaction. Run this over the affected
     * deals once, after the fields deploy, or those deals are stuck. It is idempotent and always
     * computes truth, so running it twice costs a query and changes nothing.
     *
     * ── WHY IT READS THE STORED VALUES FIRST ─────────────────────────────────────────────────
     * The extra query buys a skipped DML, and the DML is the expensive half: an Opportunity update
     * re-enters `OpportunityReviewTrigger`, whose five services are all stage-change gated and so
     * cost nothing on a flag-only write — but "costs nothing" is a property of those five services
     * today, not a guarantee, and this class should not depend on it more often than it must.
     * ⚠ An Opportunity the read does NOT return (it cannot happen for an internal principal —
     * Opportunity's internal OWD is ReadWrite, measured on `usman-dpeg` 2026-09-02 — but the
     * external model is Private) is written UNCONDITIONALLY rather than skipped. Skipping would
     * leave a stale flag, and a stale `true` is a deal closable with an open transaction.
     *
     * @param opportunityIds The deals to recompute; null/empty is a no-op.
     * @throws System.DmlException when a parent write is refused. Deliberate: see the class
     *         header's savepoint section — a refused flag write must roll the caller back, not be
     *         swallowed.
     * @example
     * // Backfill, from anonymous Apex, after the two fields deploy:
     * DealTransactionGateService.recalculate(
     *     new Map<Id, Opportunity>([SELECT Id FROM Opportunity WHERE StageName != 'Dead/Pass']).keySet());
     */
    public static void recalculate(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return;
        }

        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        lastRunInvocationCount++;

        try {
            // Seed every requested deal to the FAIL-CLOSED state. A deal with no Transaction rows
            // never appears in the aggregate below, so without this seed it would simply be absent
            // and its stale flags would survive — which for a deal whose last Transaction was just
            // deleted is precisely the "permanently unblocked" failure the brief forbids.
            Map<Id, Boolean> hasOpenByOpp = new Map<Id, Boolean>();
            Map<Id, Boolean> hasClosedByOpp = new Map<Id, Boolean>();
            for (Id opportunityId : opportunityIds) {
                hasOpenByOpp.put(opportunityId, false);
                hasClosedByOpp.put(opportunityId, false);
            }

            for (AggregateResult row
                    : TransactionSelector.aggregateStatusCountsByOpportunityIds(opportunityIds)) {
                Id opportunityId = (Id) row.get('oppId');
                if (opportunityId == null || !hasOpenByOpp.containsKey(opportunityId)) {
                    continue;
                }
                String status = (String) row.get('txnStatus');
                if (STATUS_CLOSED.equals(status)) {
                    hasClosedByOpp.put(opportunityId, true);
                } else {
                    hasOpenByOpp.put(opportunityId, true);
                }
            }

            List<Opportunity> movedFlags = new List<Opportunity>();
            Set<Id> compared = new Set<Id>();
            for (Opportunity stored
                    : OpportunitySelector.selectTransactionGateFlagsByIds(opportunityIds)) {
                compared.add(stored.Id);
                Boolean hasOpen = hasOpenByOpp.get(stored.Id);
                Boolean hasClosed = hasClosedByOpp.get(stored.Id);
                if (stored.Has_Open_Transaction__c == hasOpen
                        && stored.Has_Closed_Transaction__c == hasClosed) {
                    continue;
                }
                movedFlags.add(new Opportunity(
                    Id = stored.Id,
                    Has_Open_Transaction__c = hasOpen,
                    Has_Closed_Transaction__c = hasClosed
                ));
            }
            for (Id opportunityId : opportunityIds) {
                if (compared.contains(opportunityId)) {
                    continue;
                }
                // Unreadable rather than unchanged — write it blind. See the method header.
                movedFlags.add(new Opportunity(
                    Id = opportunityId,
                    Has_Open_Transaction__c = hasOpenByOpp.get(opportunityId),
                    Has_Closed_Transaction__c = hasClosedByOpp.get(opportunityId)
                ));
            }

            lastRunUpdatedCount += movedFlags.size();
            if (!movedFlags.isEmpty()) {
                // 🔴 SYSTEM_MODE, AND IT IS LOAD-BEARING. This runs as whoever saved the
                // Transaction — on the Day-0 handoff that is the Transactions team, who are not
                // required to hold edit CRUD on Opportunity, and the two flag fields are
                // Metadata-API-deployed so they arrive with NO FLS for anybody, System
                // Administrator included. USER_MODE here THROWS rather than degrades, and the
                // throw lands inside an after-trigger, i.e. it rolls back the user's own
                // Transaction save.
                // ⚠ SYSTEM_MODE lifts CRUD and FLS and NEVER sharing — that is a separate
                // question and it was measured, not assumed: Opportunity's INTERNAL OWD is
                // ReadWrite on `usman-dpeg` (2026-09-02), so every internal principal can already
                // write every deal and there is nothing for a `without sharing` inner class to
                // fix. If Opportunity's internal OWD is ever tightened to Private or Read Only,
                // THIS WRITE STARTS FAILING for non-owners and the remedy is a narrow
                // `private without sharing` inner class holding only this DML — never
                // `without sharing` on this service.
                // ⚠ allOrNone = true, deliberately. See the class header's savepoint section.
                Database.update(movedFlags, true, AccessLevel.SYSTEM_MODE);
            }
        } finally {
            lastRunQueryCount += Limits.getQueries() - queriesBefore;
            lastRunDmlCount += Limits.getDmlStatements() - dmlBefore;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // FLOW ENTRY POINT
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * Flow-callable recompute, so the backfill and any future data fix can be run without
     * anonymous Apex.
     *
     * List-in / List-out per `.claude/rules/invocable-rule.md`: the whole batch is recomputed in
     * ONE call to `recalculate` (one aggregate, one read, one update), and the results list is
     * index-parallel to the input.
     *
     * ⚠ This is a REPAIR tool, not a second writer. The trigger is the maintenance path; calling
     * this from a record-triggered flow on Opportunity would put a second writer on the same two
     * fields and risk a recursion the trigger's change-gate cannot see. It is idempotent and
     * always computes truth, so a wrong invocation costs a query rather than a wrong answer.
     *
     * @param requests One entry per deal to recompute.
     * @return One result per request, in the same order.
     */
    @InvocableMethod(
        label='Recalculate Deal Transaction Flags'
        description='Recomputes Has_Open_Transaction__c / Has_Closed_Transaction__c on the supplied Opportunities from their current Transaction rows. Repair/backfill only - the Transaction trigger is the maintenance path.'
        category='Opportunity'
    )
    public static List<RecalcResult> recalculateFlags(List<RecalcRequest> requests) {
        List<RecalcResult> results = new List<RecalcResult>();
        if (requests == null || requests.isEmpty()) {
            return results;
        }

        Set<Id> opportunityIds = new Set<Id>();
        for (RecalcRequest request : requests) {
            if (request != null && request.opportunityId != null) {
                opportunityIds.add(request.opportunityId);
            }
        }

        String failure = null;
        try {
            recalculate(opportunityIds);
        } catch (DmlException e) {
            failure = e.getDmlMessage(0);
        } catch (QueryException e) {
            failure = e.getMessage();
        }

        for (RecalcRequest request : requests) {
            RecalcResult result = new RecalcResult();
            result.success = failure == null
                && request != null
                && request.opportunityId != null;
            result.errorMessage = failure != null
                ? failure
                : (result.success ? null : 'No Opportunity Id was supplied.');
            results.add(result);
        }
        return results;
    }

    /** Input DTO for {@link #recalculateFlags}. */
    public class RecalcRequest {
        @InvocableVariable(required=true label='Opportunity Id' description='The deal whose transaction gate flags should be recomputed.')
        public Id opportunityId;
    }

    /** Output DTO for {@link #recalculateFlags}, index-parallel to the input list. */
    public class RecalcResult {
        @InvocableVariable(label='Success' description='True when this deal was recomputed.')
        public Boolean success;

        @InvocableVariable(label='Error Message' description='Populated only when Success is false.')
        public String errorMessage;
    }
}
