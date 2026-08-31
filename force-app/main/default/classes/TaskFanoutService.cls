/**
 * Day-0 fan-out: creates the standard Transaction task checklist (the A-J groups) as
 * standard Task records when a Transaction's contract is executed. Driven by the
 * Task_Group_Def__mdt + Transaction_Task_Def__mdt custom metadata. Called from the
 * Transaction_Task_Fanout record-triggered Flow.
 *
 * ⚠ SECOND RESPONSIBILITY SINCE 2026-08-31 (Phase 0, Story 28): it also stamps
 * `Task.Blocked_By__c`, the wire-fraud prerequisite key enforced by `TaskPrerequisiteService`.
 * THE GATE IS ONLY AS LIVE AS THIS CLASS MAKES IT — the one-off
 * `scripts/backfill-task-blocked-by.apex` covers deals that already exist, and this covers every
 * deal created from now on. Remove the stamp and new deals are silently ungated. See
 * `PREREQUISITE_SEQUENCES` for why the pair table is hardcoded here in Phase 0 and what replaces it.
 */
public with sharing class TaskFanoutService {

    // Test injection points (CMDT can't be inserted in tests, but can be built in memory).
    @TestVisible static List<Task_Group_Def__mdt> groupDefsOverride;
    @TestVisible static List<Transaction_Task_Def__mdt> taskDefsOverride;
    @TestVisible static Boolean bypassDedupe = false;

    /**
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 PHASE 0 WIRE-FRAUD PREREQUISITE PAIRS — THE SINGLE SOURCE OF TRUTH FOR `Blocked_By__c`.
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * `<group letter> => { dependent sequence => prerequisite sequence }`.
     *
     *   B3 *Send wire request to accounting with verified instructions*  blocked by
     *   B2 *Call title company to verbally verify wiring instructions (anti-fraud)*
     *   I8 *Send closing wire to title company with verified instructions* blocked by
     *   I7 *Verify wiring instructions by phone (anti-fraud)*
     *
     * ⚠ THIS IS HARDCODED, AND IT IS PHASE 0's ACCEPTED COMPROMISE — NOT THE DESIGN'S INTENT.
     * Design §5.1 mechanism 1 says the link is "seeded at fan-out … Data, not code", from a
     * `Transaction_Task_Def__mdt` column. THAT COLUMN DOES NOT EXIST YET. The type has exactly six
     * fields today — `Default_Status__c`, `Due_Day_Offset__c`, `Group_Letter__c`, `Owner_Label__c`,
     * `Sequence__c`, `Subject__c` — and adding `Blocked_By_Sequence__c` plus re-running
     * `scripts/load-transaction-task-defs.apex` is PHASE 1 work (design §10). Until then, a third
     * prerequisite pair IS a deploy of this class. Phase 1 replaces this map with the CMDT column and
     * `blockedByKeyFor` becomes a read of `d.Blocked_By_Sequence__c`; the callers do not change.
     *
     * 🔴 A PAIR CANNOT BE DEFINED IN GROUP `H2`, AND ADDING ONE HERE WOULD SILENTLY DO NOTHING.
     * `H2. Tenant Interviews & Estoppels` is the only value in the `Task_Group__c` restricted
     * picklist whose letter half is two characters, and BOTH sides of the runtime match cap the
     * letter at ONE character — `TaskPrerequisiteService.groupLetterOf` (which discards the H2 row
     * from the sibling index) and its key parser (which rejects a key like `H2|3`). So an `'H2' =>
     * {...}` entry below would produce keys nothing can resolve; the gate would fail CLOSED and make
     * those items uncompletable rather than gated. Harmless today because no H2 pair exists, and
     * recorded here because this map is exactly where someone would add one. Supporting it means
     * widening the letter parse on both sides together, plus a test.
     *
     * ⚠ IT IS STILL NOT SUBJECT-TEXT MATCHING, WHICH IS THE THING THAT MUST NOT HAPPEN. The pairs are
     * keyed on `Group_Letter__c` + `Sequence__c`, the same structured coordinates
     * `scripts/load-transaction-task-defs.apex` loads the definitions by. Nothing here reads a
     * `Subject`. See `TaskPrerequisiteService`'s header for why (RISK 1).
     */
    @TestVisible
    private static final Map<String, Map<Integer, Integer>> PREREQUISITE_SEQUENCES =
        new Map<String, Map<Integer, Integer>>{
            'B' => new Map<Integer, Integer>{ 3 => 2 },
            'I' => new Map<Integer, Integer>{ 8 => 7 }
        };

    /**
     * The `Task.Blocked_By__c` key for a checklist item, or null when that item has no prerequisite.
     *
     * PUBLIC ON PURPOSE, AND THE REASON MATTERS: `scripts/backfill-task-blocked-by.apex` calls this
     * rather than carrying its own copy of the pair table. Two copies of a fraud-control definition
     * that can silently disagree is exactly the failure mode this whole feature exists to remove —
     * the backfill and the fan-out must gate the same items or live deals and new deals diverge.
     *
     * The key format (`<UPPER letter>|<sequence>`) is parsed by
     * `TaskPrerequisiteService.resolvePrerequisites`. Both sides upper-case the letter; Apex
     * `Map.get` on a String key is CASE-SENSITIVE, so that normalisation is load-bearing, not tidying.
     *
     * @param groupLetter The item's group letter (`Task_Group_Def__mdt.Letter__c`); null/blank-safe.
     * @param sequence    The item's `Sequence__c`; null-safe.
     * @return `<letter>|<prerequisite sequence>` (e.g. `B|2`), or null when this item is not gated.
     * @example
     * tk.Blocked_By__c = TaskFanoutService.blockedByKeyFor('B', 3); // -> 'B|2'
     */
    public static String blockedByKeyFor(String groupLetter, Decimal sequence) {
        if (String.isBlank(groupLetter) || sequence == null) {
            return null;
        }
        String letter = groupLetter.trim().toUpperCase();
        Map<Integer, Integer> pairs = PREREQUISITE_SEQUENCES.get(letter);
        if (pairs == null) {
            return null;
        }
        Integer prerequisiteSequence = pairs.get(sequence.intValue());
        return prerequisiteSequence == null ? null : letter + '|' + prerequisiteSequence;
    }

    /**
     * Flow entry point. Does NOT fan out inline - it hands the work to a chunked
     * Queueable chain and returns.
     *
     * WHY ASYNC (measured, not theoretical): the checklist is 82 Tasks per
     * Transaction. A 200-record trigger chunk therefore attempts 200 x 82 =
     * 16,400 Task rows against the 10,000 DML-row limit, and blows
     * `Too many DML rows: 10001` before anything else in the cascade runs. The
     * synchronous ceiling is ~116 Transactions per transaction - that is
     * arithmetic, not inefficiency, so no amount of query tuning moves it. Any
     * fix that kept this inline would just relocate the break.
     *
     * @param requests One request per Transaction to fan out.
     */
    @InvocableMethod(label='Fan Out Transaction Tasks'
        description='Queues creation of the standard task checklist for a Transaction when its contract is executed.')
    public static void fanOut(List<InputDTO> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }
        List<Id> transactionIds = new List<Id>();
        Set<Id> seen = new Set<Id>();
        for (InputDTO request : requests) {
            if (request != null && request.transactionId != null && seen.add(request.transactionId)) {
                transactionIds.add(request.transactionId);
            }
        }
        if (transactionIds.isEmpty()) {
            return;
        }
        // Exactly ONE enqueue per transaction; the Queueable chains the rest.
        System.enqueueJob(new TaskFanoutQueueable(transactionIds, 0));
    }

    /** Flow input: one Transaction to fan out. */
    public class InputDTO {
        @InvocableVariable(required=true label='Transaction Id'
            description='The Transaction whose Day-0 checklist should be created.')
        public Id transactionId;
    }

    /**
     * The synchronous worker. Called by TaskFanoutQueueable per chunk (and
     * directly by tests that assert checklist content). Callers are responsible
     * for keeping the chunk small enough to fit the DML-row limit.
     *
     * @param transactionIds Transactions to fan out (chunked by the caller).
     */
    public static void fanOutNow(List<Id> transactionIds) {
        if (transactionIds == null || transactionIds.isEmpty()) {
            return;
        }

        // CMDT reads relocated to providers (getAll); @TestVisible overrides still win in tests.
        List<Task_Group_Def__mdt> groupDefs = groupDefsOverride != null
            ? groupDefsOverride
            : TaskGroupDefProvider.getAllOrderedBySequence();
        Map<String, Task_Group_Def__mdt> groupByLetter = new Map<String, Task_Group_Def__mdt>();
        Set<String> condFields = new Set<String>();
        for (Task_Group_Def__mdt g : groupDefs) {
            groupByLetter.put(g.Letter__c, g);
            if (String.isNotBlank(g.Condition_Field__c)) {
                condFields.add(g.Condition_Field__c);
            }
        }

        List<Transaction_Task_Def__mdt> taskDefs = taskDefsOverride != null
            ? taskDefsOverride
            : TransactionTaskDefProvider.getAllOrderedByGroupAndSequence();

        // SOQL relocated to TransactionSelector. The selector builds the same base
        // field set plus the describe-validated conditional gating fields (e.g.
        // Loan_Required__c) that each returned Transaction is read for below.
        Map<Id, Transaction__c> txns = TransactionSelector.selectByIdsWithConditionFields(
            new Set<Id>(transactionIds), condFields);

        List<Task> toInsert = new List<Task>();
        List<Transaction__c> toFlag = new List<Transaction__c>();

        for (Transaction__c t : txns.values()) {
            if (t.Tasks_Fanned_Out__c == true && !bypassDedupe) {
                continue;
            }
            Integer createdForTxn = 0;
            for (Transaction_Task_Def__mdt d : taskDefs) {
                Task_Group_Def__mdt g = groupByLetter.get(d.Group_Letter__c);
                if (g == null) {
                    continue;
                }
                // Conditional group gate (e.g. Financing only when Loan Required).
                if (g.Conditional__c == true) {
                    Boolean met = false;
                    if (String.isNotBlank(g.Condition_Field__c)) {
                        Object v = t.get(g.Condition_Field__c);
                        met = (v == true);
                    }
                    if (!met) {
                        continue;
                    }
                }
                Task tk = new Task();
                // Relate via the custom lookup (not WhatId) so checklist tasks stay out of the Activity timeline.
                tk.Transaction_Deal__c = t.Id;
                tk.OwnerId = t.OwnerId;
                tk.Subject = d.Subject__c;
                tk.Task_Group__c = g.Letter__c + '. ' + g.Group_Name__c;
                tk.Task_Sequence__c = d.Sequence__c;
                tk.Conditional__c = (g.Conditional__c == true);
                tk.Task_Owner_Label__c = String.isNotBlank(d.Owner_Label__c) ? d.Owner_Label__c : g.Owner_Label__c;
                tk.Status = String.isNotBlank(d.Default_Status__c) ? d.Default_Status__c : 'Not Started';
                // 🔴 PHASE 0 WIRE-FRAUD GATE. Stamped INLINE, in the same record construction, which
                // is only possible because `Blocked_By__c` is a Text key and not a lookup — there is
                // no target Id to wait for, so B2 and B3 still go in ONE insert and the fan-out needs
                // no second DML pass. Null for the other ~80 items, which is what makes
                // `TaskPrerequisiteService` inert for them.
                // ⚠ WITHOUT THIS LINE THE GATE IS RETRO-ONLY: only the one-off backfill would ever
                // write a key, so every deal created after Phase 0 shipped would be UNGATED while the
                // control looked live. Pinned by TaskFanoutServiceTest.fanOutStampsWireFraudPrereqKeys.
                tk.Blocked_By__c = blockedByKeyFor(g.Letter__c, d.Sequence__c);
                if (t.Contract_Executed_Date__c != null) {
                    Integer offset = d.Due_Day_Offset__c != null ? Integer.valueOf(d.Due_Day_Offset__c) : 0;
                    tk.ActivityDate = t.Contract_Executed_Date__c.addDays(offset);
                }
                toInsert.add(tk);
                createdForTxn++;
            }
            toFlag.add(new Transaction__c(Id = t.Id, Tasks_Fanned_Out__c = true, Tasks_Total__c = createdForTxn));
        }

        // 🔴 EXPLICIT SYSTEM MODE — same reason as ContractExecutionService, and this is the VERY
        // NEXT STEP of the same click. The Day-0 fan-out is invoked from the Transaction_Task_Fanout
        // flow, which declares no runInMode and therefore runs in the CALLING USER's context — the
        // deal driver who just executed the contract. That user has no Create on Task and no Edit on
        // Transaction__c (measured 2026-08-05: absent from every permission set AND from the
        // Minimum Access profile), so both statements below would throw
        // System.TypeException the instant the Transaction insert upstream started succeeding.
        //
        // Fixed together deliberately: repairing only the upstream insert would have moved the
        // failure one statement down the same transaction rather than fixing the handoff. The
        // checklist is created BY the process, so the access level is stated here rather than
        // inferred from whoever clicked.
        if (!toInsert.isEmpty()) {
            Database.insert(toInsert, true, AccessLevel.SYSTEM_MODE);
        }
        if (!toFlag.isEmpty()) {
            Database.update(toFlag, true, AccessLevel.SYSTEM_MODE);
        }
    }
}