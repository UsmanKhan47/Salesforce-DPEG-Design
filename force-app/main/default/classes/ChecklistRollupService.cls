/**
 * Recomputes the checklist counters at both levels: `Checklist__c.Items_Total__c` /
 * `Items_Complete__c`, and `Transaction__c.Tasks_Total__c` / `Tasks_Complete__c` /
 * `Tasks_Overdue__c` / `Wire_Open_Risks__c`. Invoked from `ChecklistItemTrigger` and, explicitly,
 * from `ChecklistFanoutService.reconcile`.
 *
 * layer=service. All SOQL delegated to `ChecklistSelector` / `ChecklistItemSelector`.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 APEX, NOT DECLARATIVE ROLL-UP SUMMARIES. SETTLED (design §5.3, GATE-S1) - DO NOT REOPEN.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Three independent reasons, any one of which is sufficient:
 *   1. `Tasks_Complete__c` / `Tasks_Total__c` are ASSIGNED DIRECTLY in five seed-script sites and
 *      in `TestDataFactory`. A roll-up summary is not writable, so converting them is a suite-wide
 *      compile break, and the seed scripts are how the demo org is built.
 *   2. `editable=true` FLS on a roll-up summary FAILS THE DEPLOY. Both fields are granted editable
 *      today; this repo has already paid for that trap on eight PM fields.
 *   3. `Wire_Open_Risks__c` and `Tasks_Overdue__c` CANNOT be roll-ups at all - one is conditional
 *      on two fields, the other is date-relative, and roll-up criteria cannot express a rolling
 *      date. Apex is required for two of the four regardless, and running two mechanisms side by
 *      side is strictly worse than running one.
 * A welcome side effect: all eleven `reports/Transactions/*` report on `Transaction__c`'s own
 * counters, so they survive this rewrite unchanged.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 TWO PREDICATES THAT ARE EASY TO GET WRONG, AND BOTH FAIL SILENTLY IN THE UNSAFE DIRECTION.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * (a) DONE MEANS `Completed` **OR** `Verified`. `Flag__c` is the single lossy picklist the business
 *     chose, and a rollup written against `Completed` alone silently UNDERCOUNTS every verified
 *     item - no error, just a number quietly too small. The test lives in ONE place,
 *     `ChecklistItemDomain.isDone`, so the rollup, the gate and the completion stamp cannot drift.
 * (b) `Wire_Open_Risks__c` KEYS ON `Is_Wire_Verification__c`, NEVER ON `Flag__c` AND NEVER ON
 *     SUBJECT TEXT. `TaskRollupService.cls:48` derives it from
 *     `Subject.toLowerCase().contains('anti-fraud')`, and `transactionTaskGroups.js:11` re-derives
 *     CRITICAL by regex on the same string. Both are parses of seed data and neither throws when it
 *     stops matching: the Wire Sentinel dashboard tile reads 0 open wire risks on every deal with
 *     nothing erroring anywhere. That is RISK 1 in the design and the reason this whole rewrite
 *     exists. `Flag__c` is no substitute either - completing a critical item overwrites CRITICAL,
 *     so severity is not recoverable from it.
 * ⚠ THE OPEN-WIRE PREDICATE DELIBERATELY MIRRORS THE LEGACY ONE (`is a wire item` AND
 * `Verbal_Verification_Completed__c != true`) RATHER THAN USING `isDone`. Not an oversight: the
 * Phase 4 M2 reconciliation report has to prove the two mechanisms produce the SAME number on the
 * same deal before cutover, and a predicate that quietly improved on the old one would make that
 * comparison meaningless. Changing it is a Phase 4+ decision, taken with the reconciliation in hand.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE DUAL-MODEL GUARD: THE TRANSACTION COUNTERS ARE WRITTEN ONLY FOR FANNED-OUT DEALS.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `TaskRollupService` writes the SAME FOUR FIELDS from the Task model and is still live. Without a
 * discriminator the two would fight, and the winner would be whichever fired last - a
 * non-deterministic counter on the dashboard nobody could reproduce. So this service writes the
 * Transaction level ONLY where `Checklist_Fanned_Out__c = true`, which is false for every deal in
 * the org until the Phase 4 migration deliberately sets it. The checklist level (`Items_*`) is
 * always written, because no other mechanism touches it.
 * ⚠ CONSEQUENCE, STATED SO IT IS NOT MET AS A BUG: a `Checklist__c` created by hand on a deal whose
 * guard is false gets correct group counters and does NOT move the deal's counters. That is the
 * intended coexistence behaviour, not a missing branch.
 *
 * BULK SHAPE: 2 selector calls and 2 DML statements per invocation regardless of how many
 * Transactions are passed. Never call it per record.
 *
 * @see force-app/main/default/classes/ChecklistItemTriggerHandler.cls
 * @see force-app/main/default/classes/ChecklistItemDomain.cls (the single definition of done)
 * @see agent-output/design-transaction-fsd-gaps.md §5.3, §8
 */
public with sharing class ChecklistRollupService {

    /**
     * 🔴 THE FAN-OUT RE-ENTRANCY SWITCH. `ChecklistFanoutService` inserts up to 50 x 82 = 4,100
     * items in ONE statement, which the platform fires after-insert against in 200-row batches: 21
     * firings, each spending its own SOQL and DML to recompute counters for rows the same statement
     * is still creating. The fan-out sets this around its DML and writes the counters itself, so the
     * numbers still land - they just cost 0 SOQL instead of 21. The flag is false on every other
     * path, so a standard-UI edit, an API write, Data Loader, a delete and an undelete all roll up
     * exactly as before.
     * Mirrors `OnboardingTaskRollupService.suppressTriggerRecalc`, which exists for the same reason
     * on the PM side.
     */
    private static Boolean triggerRecalcSuppressed = false;

    /**
     * Turns the fan-out re-entrancy switch on or off.
     *
     * ⚠ ALWAYS RESTORE THE PRIOR VALUE IN A `finally`, never blindly set false - `reconcile` can
     * call the fan-out helpers while already suppressed, and an unconditional reset in the inner
     * scope would re-arm the trigger halfway through the outer one's DML.
     *
     * @param suppressed true to make the trigger's recalc a no-op.
     * @example
     * Boolean prior = ChecklistRollupService.isTriggerRecalcSuppressed();
     * try { ChecklistRollupService.suppressTriggerRecalc(true); ... }
     * finally { ChecklistRollupService.suppressTriggerRecalc(prior); }
     */
    public static void suppressTriggerRecalc(Boolean suppressed) {
        triggerRecalcSuppressed = (suppressed == true);
    }

    /**
     * @return true when the trigger's recalc is currently suppressed.
     */
    public static Boolean isTriggerRecalcSuppressed() {
        return triggerRecalcSuppressed;
    }

    /**
     * Recomputes both levels for the supplied Transactions.
     *
     * @param transactionIds Deals to recompute. Null/empty-safe; nulls inside are dropped.
     * @example
     * ChecklistRollupService.recalc(new Set<Id>{ dealId });
     */
    public static void recalc(Set<Id> transactionIds) {
        if (transactionIds == null || transactionIds.isEmpty()) {
            return;
        }
        Set<Id> dealIds = new Set<Id>(transactionIds);
        dealIds.remove(null);
        if (dealIds.isEmpty()) {
            return;
        }

        // Both reads are needed: the items give the counts, and the checklists give the rows that
        // must be recomputed to ZERO when every item under them has been deleted. An items-only
        // read would leave an emptied group showing its old numbers forever.
        List<Checklist__c> checklists = ChecklistSelector.selectByTransactionIds(dealIds);
        List<Checklist_Item__c> items = ChecklistItemSelector.selectByTransactionIds(dealIds);

        Map<Id, Counters> byChecklist = new Map<Id, Counters>();
        Map<Id, Counters> byDeal = new Map<Id, Counters>();
        for (Checklist__c checklist : checklists) {
            byChecklist.put(checklist.Id, new Counters());
        }
        for (Id dealId : dealIds) {
            byDeal.put(dealId, new Counters());
        }

        Date today = Date.today();
        for (Checklist_Item__c item : items) {
            Counters group = byChecklist.get(item.Checklist__c);
            Counters deal = byDeal.get(item.Checklist__r.Transaction__c);
            Boolean done = ChecklistItemDomain.isDone(item.Flag__c);
            // (b) above: the wire predicate keys on the boolean, and mirrors the legacy shape so
            // the Phase 4 M2 reconciliation can compare the two mechanisms.
            Boolean openWireRisk = item.Is_Wire_Verification__c == true
                && item.Verbal_Verification_Completed__c != true;
            Boolean overdue = !done && item.Due_Date__c != null && item.Due_Date__c < today;
            if (group != null) {
                group.total++;
                if (done) {
                    group.complete++;
                }
            }
            if (deal != null) {
                deal.total++;
                if (done) {
                    deal.complete++;
                }
                if (overdue) {
                    deal.overdue++;
                }
                if (openWireRisk) {
                    deal.wireOpen++;
                }
            }
        }

        List<Checklist__c> checklistWrites = new List<Checklist__c>();
        for (Checklist__c checklist : checklists) {
            Counters counters = byChecklist.get(checklist.Id);
            // Only DML what actually changed - a no-op write here would re-fire this same trigger
            // path for nothing and would burn rows from the fan-out's budget.
            if (checklist.Items_Total__c == counters.total
                    && checklist.Items_Complete__c == counters.complete) {
                continue;
            }
            checklistWrites.add(new Checklist__c(
                Id = checklist.Id,
                Items_Total__c = counters.total,
                Items_Complete__c = counters.complete
            ));
        }

        // THE DUAL-MODEL GUARD. Only deals the new fan-out has claimed get their counters written;
        // every other deal is still owned by `TaskRollupService` and must not be touched.
        Map<Id, Transaction__c> deals = TransactionSelector.selectForChecklistFanout(
            dealIds, new Set<String>());
        List<Transaction__c> dealWrites = new List<Transaction__c>();
        for (Id dealId : dealIds) {
            Transaction__c deal = deals.get(dealId);
            if (deal == null || deal.Checklist_Fanned_Out__c != true) {
                continue;
            }
            Counters counters = byDeal.get(dealId);
            dealWrites.add(new Transaction__c(
                Id = dealId,
                Tasks_Total__c = counters.total,
                Tasks_Complete__c = counters.complete,
                Tasks_Overdue__c = counters.overdue,
                Wire_Open_Risks__c = counters.wireOpen
            ));
        }

        new RollupWrites().commitRollups(checklistWrites, dealWrites);
    }

    /**
     * Resolves a set of `Checklist__c` ids to their deals and recomputes those deals. The entry
     * point the trigger handler uses, because a `Checklist_Item__c` in `Trigger.new` carries only
     * its `Checklist__c` lookup.
     *
     * ⚠ A CHECKLIST THAT NO LONGER EXISTS SIMPLY DROPS OUT, and that is a real hole with a real
     * mitigation rather than a theoretical one: on a cascade delete the parent may already be gone
     * by the time the child's after-delete fires, so its deal cannot be reached from here.
     * `ChecklistFanoutService.reconcile` - the only production path that deletes a whole checklist -
     * calls `recalc` explicitly afterwards for exactly this reason.
     *
     * @param checklistIds `Checklist__c` ids touched by this save. Null/empty-safe.
     * @example
     * ChecklistRollupService.recalcForChecklistIds(ChecklistItemDomain.collectChecklistIds(items));
     */
    public static void recalcForChecklistIds(Set<Id> checklistIds) {
        if (checklistIds == null || checklistIds.isEmpty()) {
            return;
        }
        Set<Id> dealIds = new Set<Id>();
        for (Checklist__c checklist : ChecklistSelector.selectByIds(checklistIds).values()) {
            if (checklist.Transaction__c != null) {
                dealIds.add(checklist.Transaction__c);
            }
        }
        recalc(dealIds);
    }

    /** Per-parent tallies. */
    private class Counters {
        Integer total = 0;
        Integer complete = 0;
        Integer overdue = 0;
        Integer wireOpen = 0;
    }

    /**
     * 🔴 THE ROLLUP WRITES, WHICH MUST RUN **WITHOUT SHARING** - AND THIS IS A SEPARATE DECISION
     * FROM `SYSTEM_MODE`, NOT A CONSEQUENCE OF IT.
     *
     * `SYSTEM_MODE` lifts CRUD and FLS and **NEVER** sharing. `Transaction__c` is Private OWD, and
     * `Checklist_Item__c` is master-detail with `writeRequiresMasterRead=false`, which means a
     * principal needs only READ on the deal to EDIT one of its checklist items. So the ordinary case
     * is a user who can legitimately tick an item on a deal they do not own and cannot edit - and
     * under `with sharing` this counter update would then not apply.
     * THIS PROJECT HAS A LIVE INCIDENT OF EXACTLY THAT SHAPE: an approval's parent write failed
     * silently for every approver who did not OWN the record, worked in every test because the
     * test's approver WAS the owner, and was swallowed by `allOrNone = false`. `TaskRollupService`
     * documents the same hazard and accepts it as a residual because on ITS reported path the runner
     * was always the owner; that accident does not hold here, so the decision is taken rather than
     * inherited.
     *
     * Scoped as narrowly as Apex allows: `private`, one class, one method, reached only from
     * `recalc`. Inner classes do NOT inherit the outer class's sharing keyword, so it is declared
     * explicitly and `ChecklistRollupService` itself STAYS `with sharing`. It writes ONLY derived
     * counters - no field a user supplied, nothing read back, nothing returned to a caller - so it
     * cannot leak a row the running user could not otherwise see.
     * PRECEDENT: `OnboardingTaskRollupService.RollupWrites`, `OnboardingSelector.IdempotencyReads`.
     *
     * `allOrNone = true` so this can never fail silently again. If the write is genuinely impossible
     * the caller's save fails loudly, which is the correct outcome for counters the dashboard, the
     * KPIs and the wire-risk tile all read.
     *
     * ⚠ Apex forbids static methods on inner classes, hence the instance method and the
     * `new RollupWrites()` at the call site.
     */
    private without sharing class RollupWrites {

        /**
         * Persists the recomputed counters at both levels.
         *
         * @param checklistWrites Sparse `Checklist__c` rows carrying Id + Items_*; may be empty.
         * @param dealWrites      Sparse `Transaction__c` rows carrying Id + the four counters; may
         *                        be empty (every deal still on the legacy model).
         * @throws System.DmlException on a platform save failure (allOrNone = true, by design).
         */
        private void commitRollups(
            List<Checklist__c> checklistWrites,
            List<Transaction__c> dealWrites
        ) {
            if (!checklistWrites.isEmpty()) {
                Database.update(checklistWrites, true, AccessLevel.SYSTEM_MODE);
            }
            if (!dealWrites.isEmpty()) {
                Database.update(dealWrites, true, AccessLevel.SYSTEM_MODE);
            }
        }
    }
}
