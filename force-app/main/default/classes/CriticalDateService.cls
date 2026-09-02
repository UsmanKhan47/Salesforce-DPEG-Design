/**
 * Idempotently projects a deal's own authoritative dates into `Critical_Date__c` rows, so the
 * Critical Dates countdown report and dashboard component have data. Design §2.6, §5.5.
 *
 * layer=service. All SOQL delegated to `TransactionSelector.selectForCriticalDates` and
 * `CriticalDateSelector.selectExistingKeysByTransactionIds`.
 *
 * ── PRODUCTION CALLERS (authoritative list — ARCHITECTURE.md §2 makes this header the inventory) ──
 *   1. `scripts/seed-critical-dates.apex`                    — an operator, deliberately, in bulk.
 *   2. `ChecklistOutcomeService.applyForCompletedItems`      — an ORDINARY USER completing checklist
 *      item **A5** ("Log critical dates into Salesforce deal record"), one deal at a time, in the
 *      same transaction as their own checklist save. Added by Phase 5, 2026-09-02.
 * ⚠ NO TRIGGER CALLS THIS CLASS. Caller 2 is not a re-wiring of the removed
 * `TransactionTriggerHandler` arm and must not be read as permission to restore it — see the
 * GATE-B3 block below, and `TransactionTriggerHandler.afterUpdate` for the removal conditions.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * THE RULES BELOW ARE LIFTED VERBATIM FROM `scripts/seed-critical-dates.apex`, WHICH IS THE SPEC.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * That script reasoned all of this through once already and the reasoning is not re-derived here;
 * the script is now repointed to call this class so the two cannot drift.
 *
 *   PINNING - the Transaction's own field is the SYSTEM OF RECORD and the Critical Date is a
 *     DERIVED PROJECTION of it (design GATE-B4). A Critical Date that disagrees with the deal
 *     record is a defect, so:
 *         Closing Date    <= Target_Close_Date__c
 *         Feasibility End <= Feasibility_Deadline__c
 *     A type with no pinned source and no supplied date is simply not created - this service never
 *     invents a deadline out of an offset the way the demo seed script may.
 *
 *   COHERENCE GATES - evaluated against each deal's real values:
 *     • Stage__c = 'Closed' or 'Post-Closing', or Status__c = 'Closed' -> the whole deal is skipped.
 *       A closed deal has no UPCOMING critical dates.
 *     • Stage__c = 'Closing Prep' and type = 'Feasibility End'   -> dropped. By closing prep the
 *       feasibility period has demonstrably ended.
 *     • Feasibility_Missed__c = true and type = 'Feasibility End' -> dropped. A future feasibility
 *       end on a deal that already missed feasibility is a contradiction.
 *     • Loan_Required__c != true and type = 'Loan Commitment'     -> dropped.
 *     NOT gated, deliberately: 'Earnest Money Due' is NOT suppressed when the money has already been
 *     wired. Additional / hard-money deposits after the initial wire are normal in CRE.
 *
 *   IDEMPOTENCY - keyed on `(Transaction Id + Type__c)`, never on a coarse "any rows exist?" early
 *     exit. Strictly safer AND self-healing: a partially failed run, or a later addition to the
 *     type set, is repaired by re-running. The same key also enforces "no two rows of one Type for
 *     one Transaction" WITHIN a run.
 *     🔴 THE KEY IS READ `without sharing` - see `CriticalDateSelector`'s header. A sharing-filtered
 *     idempotency guard does not fail safe, it INVERTS INTO A DUPLICATE-MAKER, and `Critical_Date__c`
 *     is Private OWD with no owner-based sharing rule.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 UNRESOLVED CONSEQUENCE - GATE-B3 IS STILL OPEN AND THIS CLASS IS WHAT MAKES IT BITE.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `Critical_Date__c.Transaction__c` is `required=true` with `deleteConstraint=Restrict`. Once a
 * Critical Date exists under a Transaction, THAT TRANSACTION CAN NEVER BE DELETED. Today only a demo
 * seed script creates rows, so the blast radius is contained; wiring this to automation makes
 * `DELETE_FAILED` the default for every deal that has ever changed stage - including in scratch
 * rebuilds, and including `scripts/seed-transactions.apex:31`'s `delete [SELECT Id FROM
 * Transaction__c]`, which already throws for this reason on a seeded org.
 * 🔴 MITIGATION, AMENDED 2026-09-01 — THIS CLASS IS NOT WIRED TO ANY TRIGGER AT ALL. This paragraph
 * said `TransactionTriggerHandler` wires it to AFTER UPDATE ONLY. That arm was REMOVED by user
 * decision: with GATE-B2 (`Contract Executed` missing from the restricted `Type__c`) and GATE-B4
 * (source of truth) still open, wiring it live would have made Phase 2 non-neutral for every deal in
 * the org on its next stage move. The TRIGGER window remains closed.
 *
 * 🔴 AMENDED AGAIN 2026-09-02 — THE WINDOW IS NO LONGER CLOSED. THIS PARAGRAPH USED TO END "a deal
 *    only becomes undeletable if someone runs the seed script against it." THAT IS NOW FALSE, AND
 *    THIS IS THE PARAGRAPH SOMEONE READS TO ANSWER GATE-B3, SO IT MUST NOT LIE.
 * Phase 5 added a SECOND production caller: `ChecklistOutcomeService.applyForCompletedItems` invokes
 * `ensureFor` when checklist item **A5** ("Log critical dates into Salesforce deal record") is
 * completed. So a deal becomes permanently undeletable the moment an ordinary user ticks A5 on it -
 * no script, no administrator, no deploy.
 * WHAT IS AND IS NOT DIFFERENT FROM THE TRIGGER ARM:
 *   • STILL NARROWER. It is opt-in per deal, by the person whose job that step is, on a step whose
 *     subject literally says to log the dates. It is NOT every deal in the org on its next stage
 *     move, which is what the removal was protecting against.
 *   • BUT IT IS ORDINARY USERS, NOT OPERATORS. The seed-script framing ("someone runs it") no longer
 *     describes the reachable population. Any deal whose group A is worked will become undeletable
 *     in the normal course of business.
 *   • GATE-B2 IS UNAFFECTED: this class writes only `Closing Date`, `Feasibility End` and
 *     `Loan Commitment`, all three valid today. `Contract Executed` is still absent and must stay
 *     absent until the picklist value is deployed.
 * ⇒ GATE-B3 IS NOW A LIVE QUESTION FOR THE CHECKLIST, NOT A DEFERRED ONE FOR THE TRIGGER. If the
 *   business refuses the undeletability, the A5 call is in scope of that answer too.
 *
 * ⚠ TRANSACTION SCOPE ON THE A5 PATH — the dormancy claim below is also retired. `ensureFor` runs in
 * the SAME transaction as the user's checklist completion, so a throw here rolls back their save.
 * The `allOrNone = false` insert means a single bad ROW cannot do that (it is logged and skipped),
 * but a failure in the two READS, or a `Database.insert` that throws outright, still would. That was
 * the "rolls back the user's own save" consequence recorded as dormant while only the script called
 * this class; it is dormant no longer.
 *
 * THE SERVICE IS NOT DEAD CODE AND MUST NOT BE DELETED AS SUCH: `scripts/seed-critical-dates.apex`
 * and `ChecklistOutcomeService` both call it directly, and it is the tested, reviewed implementation
 * the trigger arm will use when the gates close. See `TransactionTriggerHandler.afterUpdate` for the
 * full re-wiring conditions, recorded at the removal site.
 * GATE-B3 is still the real answer to the delete constraint - either accept it, or relax the lookup
 * to `SetNull` + `required=false` with a validation rule in its place - and it is a
 * business/architecture decision, not one this class can take.
 *
 * BULK SHAPE: 2 selector calls and 1 DML statement per invocation regardless of deal count.
 *
 * @see scripts/seed-critical-dates.apex (the specification, now repointed to call this)
 * @see agent-output/design-transaction-fsd-gaps.md §2.4, §2.5, §2.6, §5.5
 */
public with sharing class CriticalDateService {

    /**
     * The five values of the RESTRICTED picklist `Critical_Date__c.Type__c`.
     *
     * 🔴 RESTRICTED PICKLISTS ARE ENFORCED BY DML ON THIS PROJECT (measured repeatedly; the repo has
     * been wrong about this in the other direction more than once). A stale literal here is a
     * row-level `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`, not a coercion.
     * ⚠ `Contract Executed` IS NOT ONE OF THEM. The FSD asks for a Contract Executed critical date;
     * the value does not exist in the picklist and writing it fails. That is design GATE-B2, it is
     * unanswered, and this class deliberately does NOT create that row rather than guessing at a
     * picklist change. Adding the value is a metadata deploy that must land BEFORE any Apex writing
     * it - record-type/picklist values first, Apex second, always.
     */
    public static final String TYPE_CLOSING_DATE = 'Closing Date';

    /** Feasibility period end. Pinned to `Transaction__c.Feasibility_Deadline__c`. */
    public static final String TYPE_FEASIBILITY_END = 'Feasibility End';

    /** Loan commitment deadline. Suppressed entirely when the deal needs no loan. */
    public static final String TYPE_LOAN_COMMITMENT = 'Loan Commitment';

    /** Deal stages at which a deal has no upcoming critical dates at all. */
    private static final Set<String> TERMINAL_STAGES = new Set<String>{ 'Closed', 'Post-Closing' };

    /** Rows created by the last run. Test instrumentation only. */
    @TestVisible
    private static Integer lastRunCreatedCount = 0;

    /** Rows the idempotency key suppressed on the last run. Test instrumentation only. */
    @TestVisible
    private static Integer lastRunSkippedExistingCount = 0;

    /** Rows a coherence gate dropped on the last run. Test instrumentation only. */
    @TestVisible
    private static Integer lastRunSkippedIncoherentCount = 0;

    /** Rows that failed to insert on the last run (partial success is tolerated). */
    @TestVisible
    private static Integer lastRunFailureCount = 0;

    /** Zeroes the instrumentation. Test-only; production never calls it. */
    @TestVisible
    private static void resetRunCounters() {
        lastRunCreatedCount = 0;
        lastRunSkippedExistingCount = 0;
        lastRunSkippedIncoherentCount = 0;
        lastRunFailureCount = 0;
    }

    /**
     * Creates any missing Critical Dates for the supplied deals, per the pinning and coherence rules
     * in the class header. Safe to call repeatedly - a second identical run creates nothing.
     *
     * ⚠ `allOrNone = false`, WITH EVERY FAILURE COUNTED. One deal whose data trips a validation rule
     * must not discard the rows for the other 199, and this runs inside somebody's save: a hard
     * failure here would roll back a stage change that has nothing to do with critical dates. The
     * counter is what stops that tolerance becoming silence.
     *
     * @param transactionIds Deals to project. Null/empty-safe; nulls inside are dropped.
     * @return The number of `Critical_Date__c` rows actually created.
     * @example
     * Integer created = CriticalDateService.ensureFor(new Set<Id>{ dealId });
     */
    public static Integer ensureFor(Set<Id> transactionIds) {
        resetRunCounters();
        if (transactionIds == null || transactionIds.isEmpty()) {
            return 0;
        }
        Set<Id> dealIds = new Set<Id>(transactionIds);
        dealIds.remove(null);
        if (dealIds.isEmpty()) {
            return 0;
        }

        Map<Id, Transaction__c> deals = TransactionSelector.selectForCriticalDates(dealIds);
        if (deals.isEmpty()) {
            return 0;
        }
        Set<String> claimedKeys =
            CriticalDateSelector.selectExistingKeysByTransactionIds(deals.keySet());

        List<Critical_Date__c> toCreate = new List<Critical_Date__c>();
        for (Transaction__c deal : deals.values()) {
            // Gate 1 - a closed or post-closing deal has no upcoming critical dates at all.
            if (TERMINAL_STAGES.contains(deal.Stage__c) || deal.Status__c == 'Closed') {
                continue;
            }
            addIfWanted(toCreate, claimedKeys, deal, TYPE_CLOSING_DATE, deal.Target_Close_Date__c);
            addIfWanted(toCreate, claimedKeys, deal, TYPE_FEASIBILITY_END,
                feasibilityEndFor(deal));
            addIfWanted(toCreate, claimedKeys, deal, TYPE_LOAN_COMMITMENT,
                loanCommitmentDateFor(deal));
        }
        if (toCreate.isEmpty()) {
            return 0;
        }

        // ⚠ SYSTEM_MODE for CRUD/FLS - this is automation acting on the saving user's behalf, and
        // `Critical_Date__c` is a Metadata-API-deployed object whose fields carry no grants for the
        // deal drivers who trigger it. Sharing is NOT lifted: an insert creates a row the running
        // user then owns, so there is nothing for sharing to deny.
        Database.SaveResult[] results = Database.insert(toCreate, false, AccessLevel.SYSTEM_MODE);
        for (Database.SaveResult result : results) {
            if (result.isSuccess()) {
                lastRunCreatedCount++;
            } else {
                lastRunFailureCount++;
            }
        }
        return lastRunCreatedCount;
    }

    /**
     * The feasibility-end date, or null when a coherence gate drops the row.
     *
     * @param deal The deal, with its stage and feasibility fields populated.
     * @return The pinned date, or null when the type is incoherent for this deal.
     */
    private static Date feasibilityEndFor(Transaction__c deal) {
        if (deal.Stage__c == 'Closing Prep' || deal.Feasibility_Missed__c == true) {
            lastRunSkippedIncoherentCount++;
            return null;
        }
        return deal.Feasibility_Deadline__c;
    }

    /**
     * The loan-commitment date, or null when the deal needs no loan.
     *
     * ⚠ THERE IS NO `Loan_Commitment_Date__c` ON `Transaction__c` TODAY, and this service does not
     * invent one. `Loan__c.Commitment_Date__c` (Phase 1 schema) is the intended source and wiring it
     * is Phase 5 work, so this returns null and the row is simply not created until then. That is
     * deliberate: projecting a date the deal record does not hold would violate the pinning rule the
     * whole design of this service rests on.
     *
     * @param deal The deal, with `Loan_Required__c` populated.
     * @return null in every case today; the gate is retained so Phase 5 has one line to change.
     */
    private static Date loanCommitmentDateFor(Transaction__c deal) {
        if (deal.Loan_Required__c != true) {
            lastRunSkippedIncoherentCount++;
        }
        return null;
    }

    /**
     * Adds one projected row when it has a date and its `(Transaction + Type)` key is unclaimed.
     *
     * @param toCreate    Accumulator.
     * @param claimedKeys Keys already taken, mutated so a duplicate WITHIN this run is impossible.
     * @param deal        The parent deal.
     * @param dateType        A value of the restricted `Type__c` picklist.
     * @param dueDate     The pinned date, or null to skip.
     */
    private static void addIfWanted(
        List<Critical_Date__c> toCreate,
        Set<String> claimedKeys,
        Transaction__c deal,
        String dateType,
        Date dueDate
    ) {
        if (dueDate == null) {
            return;
        }
        String key = String.valueOf(deal.Id) + '|' + dateType;
        if (claimedKeys.contains(key)) {
            lastRunSkippedExistingCount++;
            return;
        }
        claimedKeys.add(key);
        toCreate.add(new Critical_Date__c(
            Transaction__c = deal.Id,
            Type__c = dateType,
            Due_Date__c = dueDate
        ));
    }
}
