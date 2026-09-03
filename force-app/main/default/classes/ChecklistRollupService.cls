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
 * 🔴 THE GUARD IS ONE-SIDED, AND THAT IS A KNOWN, UNCLOSED DESIGN COLLISION - NOT A CLAIM THAT THE
 * TWO MODELS ARE SAFELY SEPARATED. It stops the CHECKLIST side writing to a deal the Task model
 * still owns. NOTHING STOPS THE TASK SIDE. `TaskRollupService` recomputes all four fields from
 * `Task` rows on any checklist-Task save, for ANY deal, including one whose
 * `Checklist_Fanned_Out__c` is already true. Today that is harmless because no production deal has
 * the flag set; at Phase 4 step M1 it stops being harmless, because both models are live on the
 * same deal and the LAST WRITER WINS non-deterministically. The M2 reconciliation is supposed to
 * prove the two agree before cutover, but "supposed to" is not a mechanism.
 * THE SMALLEST CORRECT TIEBREAK, WHEN IT IS TIME: teach `TaskRollupService` to skip deals whose
 * `Checklist_Fanned_Out__c` is true - strictly narrowing, no new fields, no report repoint, and it
 * inverts cleanly (the Task model owns a deal until the Checklist model claims it). It is
 * deliberately NOT done in Phase 2, because Phase 2 must be behaviour-neutral and that change edits
 * a live class. It is a scope decision for the migration phase, not an improvisation for this one.
 *
 * ⚠ CONSEQUENCE, STATED SO IT IS NOT MET AS A BUG: a `Checklist__c` created by hand on a deal whose
 * guard is false gets correct group counters and does NOT move the deal's counters. That is the
 * intended coexistence behaviour, not a missing branch.
 *
 * BULK SHAPE: flat in the number of Transactions passed — never a function of record count. Never
 * call it per record.
 *
 * ⚠ THE COUNT ITSELF WAS WRONG UNTIL 2026-08-31 AND IS CORRECTED HERE RATHER THAN QUIETLY EDITED,
 * because the fan-out's own governor arithmetic was derived FROM IT and understated its worst case
 * fourfold (see `ChecklistFanoutService`'s header):
 *   `recalc(Set<Id>)`                : **3** selector calls — `ChecklistSelector
 *                                      .selectByTransactionIds`, `ChecklistItemSelector
 *                                      .selectByTransactionIds`, and `TransactionSelector
 *                                      .selectForChecklistFanout` for the guard check. Plus up to
 *                                      2 DML (the `Checklist__c` writes and the `Transaction__c`
 *                                      writes), each skipped when its list is empty.
 *   `recalcForChecklistIds(Set<Id>)` : **4** — its own `ChecklistSelector.selectByIds` to map
 *                                      checklists to deals, then everything `recalc` spends. THIS
 *                                      IS THE TRIGGER PATH, so it is the figure that matters for
 *                                      any cascade estimate.
 * The previous "2 and 2" counted neither the guard read nor the trigger path's own mapping read.
 *
 * 🔴 ANY PAYLOAD CARRYING THIS CLASS MUST NAME `ChecklistRollupServiceTest` EXPLICITLY. Measured
 * during the 2026-09-02 Phase 4 + Phase 5 pre-flight: this class was in the payload and its test
 * class was not, because the rollup is SUPPRESSED on both of the paths the payload's own tests
 * exercise (the fan-out and the migration both set the flag and write their counters themselves).
 * So the coverage a deploy "happens to get" for this class is close to nothing, with zero errors
 * reported — a silent coverage rollback. Do not rely on incidental coverage for a class whose main
 * production path is deliberately switched off during bulk operations.
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
            Counters groupCounters = byChecklist.get(item.Checklist__c);
            Counters deal = byDeal.get(item.Checklist__r.Transaction__c);
            Boolean done = ChecklistItemDomain.isDone(item.Flag__c);
            // (b) above: the wire predicate keys on the boolean, and mirrors the legacy shape so
            // the Phase 4 M2 reconciliation can compare the two mechanisms.
            Boolean openWireRisk = item.Is_Wire_Verification__c == true
                && item.Verbal_Verification_Completed__c != true;
            Boolean overdue = !done && item.Due_Date__c != null && item.Due_Date__c < today;
            if (groupCounters != null) {
                groupCounters.total++;
                if (done) {
                    groupCounters.complete++;
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
     * 🔴 THE ROLLUP WRITES, WHICH RUN **WITHOUT SHARING** - A SEPARATE DECISION FROM
     * `SYSTEM_MODE`, NOT A CONSEQUENCE OF IT. ⚠ READ THE 2026-09-02 CORRECTION BELOW BEFORE
     * CITING THIS BLOCK AS PRECEDENT: THE SHARING HALF OF ITS ORIGINAL ARGUMENT WAS WRONG.
     *
     * `SYSTEM_MODE` lifts CRUD and FLS and **NEVER** sharing, so the two questions are asked
     * separately.
     *
     * THE CRUD HALF IS SETTLED AND REAL. `DPEG_Checklist_Edit` grants `allowEdit=false` on
     * `Transaction__c` (verified 2026-09-02), so a principal holding only that set cannot write
     * these counters at all. `SYSTEM_MODE` covers exactly that, on its own, with no sharing
     * escalation required.
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 CORRECTION 2026-09-02 - THE SHARING HALF WAS ARGUED FROM AN INVERTED FACT.
     *    THE ORIGINAL JUSTIFICATION IS VOID. DO NOT CITE IT OR COPY IT INTO A NEW CLASS.
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * This block used to read: "`Checklist_Item__c` is master-detail with
     * `writeRequiresMasterRead=false`, which means a principal needs only READ on the deal to EDIT
     * one of its checklist items." **THAT IS BACKWARDS.** `writeRequiresMasterRead=false` is the
     * STRICTER setting: it requires read AND WRITE access on the master to create, edit or delete
     * the detail. `true` is the one that needs only read. Both links carry `false`
     * (`Checklist__c.Transaction__c` and `Checklist_Item__c.Checklist__c`, verified 2026-09-02),
     * and the chain is two hops, so editing an item requires EDIT-level sharing on the Transaction.
     *
     * ⇒ ON THE TRIGGER PATH THE PREMISE THEREFORE DOES NOT EXIST. The user whose save fired
     *   `ChecklistItemTrigger` demonstrably HAD edit access to the deal, or the platform would have
     *   refused their item edit before this code ever ran. The "ticks an item on a deal they cannot
     *   edit" case is not an edge case that rarely happens - it cannot happen.
     *   `ChecklistItemService`'s header and `Checklist__c.object-meta.xml` both state the flag
     *   CORRECTLY; this block was the outlier, and it was the sole justification for the
     *   escalation below.
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 RE-EXAMINED 2026-09-02 AGAINST A MEASURED OUTAGE - AND THE ANSWER IS STILL **NO**.
     *    THIS CLASS STAYS `with sharing`. THE NEGATIVE RESULT IS RECORDED HERE BECAUSE A
     *    NEGATIVE RESULT NOBODY WROTE DOWN GETS RE-LITIGATED EVERY TIME.
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * The block that stood here recorded the REMOVAL of a `without sharing` escalation and set
     * the bar for restoring it: "IT MUST COME WITH A NAMED CALLER IN THIS BLOCK. Never flip it
     * back on a hypothetical." That bar was tested on 2026-09-02 and HELD.
     *
     * WHAT HAPPENED. A production failure was measured on the LEGACY model's identical shape -
     * `AsyncApexJob 707iw0000046Rh6AAE`, deal `a0Riw000000Ao3ZEAS`, user `005iw000000AJhJAAW`,
     * `UserRecordAccess` = HasReadAccess true / HasEditAccess **FALSE** / MaxAccessLevel 'Read'.
     * `ContractExecutionService.cls:359` (2026-08-28) hands the Day-0 `Transaction__c` to the
     * Transactions team on insert while the whole downstream chain keeps running as the DEAL
     * DRIVER, so `TaskRollupService`'s counter write - `with sharing` + `SYSTEM_MODE`, the same
     * shape as `RollupWrites` below - was refused and rolled back all 82 Day-0 Tasks. The obvious
     * inference was that THIS class carries the same defect and must be flipped to
     * `without sharing` in the same change.
     *
     * ⇒ 🔴 THAT INFERENCE IS WRONG, AND IT WAS TRACED STATEMENT BY STATEMENT RATHER THAN ASSUMED.
     *   **THE DAY-0 DRIVER NEVER REACHES THIS CLASS.** `ChecklistFanoutService.cls:296` calls
     *   `suppressTriggerRecalc(true)` and holds it across ALL FOUR of its DML statements,
     *   restoring the prior value in a `finally`. The fan-out then writes the four
     *   `Transaction__c` counters ITSELF, from the `DealTally` it built in memory. So on the
     *   Day-0 chain this class's `recalc` is not merely harmless - it is NOT INVOKED. The Day-0
     *   driver is therefore NOT a named caller for this class, and flipping the keyword on it
     *   would be flipping on a hypothesis this investigation FALSIFIED - precisely what the bar
     *   above forbids.
     *
     * ✅ THE OTHER LIVE CALLERS STILL HOLD EDIT BY CONSTRUCTION, RE-CHECKED THE SAME DAY:
     *   • `ChecklistItemTrigger` (after contexts) - `writeRequiresMasterRead=false` on BOTH links
     *     is the STRICTER setting (read AND WRITE on the master), so a user who just saved an item
     *     provably holds Edit on the deal or the platform would have refused their save first.
     *     Not an edge case; it cannot happen.
     *   • `ChecklistFanoutService.reconcile` -> its trailing explicit `recalc` fires from
     *     `TransactionTriggerHandler.afterUpdate` ONLY when `Loan_Required__c` changed - the
     *     principal just edited the deal.
     *   • `ChecklistMigrationService` (Phase 4 M1) - suppresses this rollup across all four of its
     *     statements and writes the counters itself. The future-migration premise the original
     *     escalation rested on was tested by reality and did not need it.
     *
     * ⇒ ZERO callers require the escalation, on evidence rather than on the absence of evidence.
     *   This is now a PROVEN DISTINCTION rather than an untested claim, because the sibling
     *   `TaskRollupService` DID need it, in the same investigation, on the same day, for the same
     *   principal - and got it (`TaskRollupService.RollupWrites`, plus its READ half at
     *   `TaskSelector.RollupReads`; the two moved together, see below).
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 TRIP WIRE - THE ONE THING THAT KILLS THE PREMISE ABOVE. READ THIS BEFORE EDITING
     *    `ChecklistFanoutService`, NOT AFTER.
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * The entire argument rests on ONE line in ANOTHER class: **`ChecklistFanoutService.cls:296`,
     * `ChecklistRollupService.suppressTriggerRecalc(true)`**, held across all four fan-out
     * statements. IF THAT SUPPRESSION IS EVER REMOVED, NARROWED, OR MOVED INSIDE THE FOUR
     * STATEMENTS, THE DAY-0 DRIVER REACHES THIS CLASS IMMEDIATELY and this block is void - the
     * `Database.update(dealWrites, ...)` below then fails for exactly the reason
     * `TaskRollupService`'s did, and rolls back the whole checklist fan-out.
     * THE SAME APPLIES IF: a Schedulable, batch or Queueable caller of `recalc` appears; anything
     * calls `recalc` / `recalcForChecklistIds` from a context whose principal did not just edit
     * the deal; or `writeRequiresMasterRead` flips to `true` on either master-detail link.
     * ⇒ ANY of those ⇒ RE-OPEN THIS BLOCK AND RE-DECIDE. Do not assume the answer is still no.
     * ⚠ Note the coupling is INVISIBLE FROM THIS FILE. A change to `ChecklistFanoutService`'s
     *   suppression looks local and is not; that is why the trip wire is written here in the
     *   class whose premise dies, and cross-referenced there.
     *
     * 🔴 AND IF IT IS EVER RESTORED, THE READ MUST BE ANSWERED IN THE SAME CHANGE. The Task-side
     * fix proved this the hard way: escalating a rollup's WRITE while its READ stays filtered does
     * not fail, it writes ZEROES successfully and puts "no open wire risks" on a deal that has
     * two. This class is currently SAFE ON THE READ SIDE FOR A STRUCTURAL REASON, and it is
     * recorded here so a future restorer does not have to re-derive it: `Checklist__c` and
     * `Checklist_Item__c` are `ControlledByParent` with NO `OwnerId` at all, so any principal who
     * can read the deal reads EVERY checklist and item on it; and the guard loop below skips any
     * deal absent from the guard read, so an unreadable deal gets no write. Readable deal ⇒
     * complete item read; unreadable deal ⇒ no write. There is no state in which this class
     * publishes counters computed from a partial view.
     * ⚠ THAT SECOND HALF DEPENDS ON `TransactionSelector.selectForChecklistFanout` STAYING
     *   SHARING-FILTERED. It was deliberately NOT escalated on 2026-09-02 for this reason -
     *   `TaskRollupService` got its own `selectClaimFlagsForTaskRollup` instead. Escalating the
     *   shared method in place would silently convert this class's fail-closed guard into a
     *   fail-open one.
     * ⚠ THE `ControlledByParent` PROPAGATION HALF IS REASONED, NOT MEASURED. That a principal
     *   holding `viewAllRecords` on `Transaction__c` reads its `ControlledByParent` details is
     *   standard platform behaviour and is the stated premise of `Checklist__c.object-meta.xml` -
     *   but that file itself records that it "could not be measured (no org access this session)",
     *   and it was not measured on 2026-09-02 either. It is the ONE assumption this read-side
     *   conclusion rests on. Probe before relying on it in a new context:
     *   `UserRecordAccess` for the driver against a `Checklist__c` / `Checklist_Item__c` on a deal
     *   he does not own. If it is false, this class needs a read escalation after all.
     *
     * ⚠ CORRECTED 2026-09-02, IN THE CALLER LIST ABOVE: the `ChecklistFanoutQueueable` bullet used
     * to read "runs as its enqueuer, WHO CREATED OR EDITED THE DEAL". That conflates two different
     * access facts and the first one is false - the enqueuer CREATED the deal and, since
     * 2026-08-28, provably CANNOT EDIT IT (`MaxAccessLevel = 'Read'`, measured). The bullet's
     * CONCLUSION survives, but only because of the suppression above, NOT because of access. If
     * anyone cites that bullet as evidence of access, they are citing a corrected error.
     *
     * ⚠ `TaskRollupService` documented a related hazard and accepted it as a residual until
     * 2026-09-02, when it stopped being residual and became the default Day-0 path. That is a
     * different object with a different relationship; its reasoning does not transfer here in
     * either direction, and the fact that IT was escalated is not an argument that THIS should be.
     *
     * ⚠ THE INNER CLASS IS KEPT DELIBERATELY, EVEN THOUGH ITS ONLY REASON FOR EXISTING WAS TO SCOPE
     * THE ESCALATION. Collapsing it into a private static method is the obvious follow-up and is
     * NOT bundled here: it would turn a one-word, reviewable sharing change to a deployed class
     * into a structural one, in a payload that already carries two phases. Inner classes do NOT
     * inherit the outer class's sharing keyword, so the mode is declared EXPLICITLY rather than
     * left to the caller.
     * It writes ONLY derived counters - no field a user supplied, nothing read back, nothing
     * returned to a caller - so it could never leak a row the running user cannot otherwise see;
     * that was true before this change and is why the escalation was low-risk rather than harmless.
     * PRECEDENT FOR THE SHAPE (not for the mode): `OnboardingTaskRollupService.RollupWrites`.
     *
     * `allOrNone = true` so this can never fail silently again. If the write is genuinely impossible
     * the caller's save fails loudly, which is the correct outcome for counters the dashboard, the
     * KPIs and the wire-risk tile all read.
     *
     * ⚠ Apex forbids static methods on inner classes, hence the instance method and the
     * `new RollupWrites()` at the call site.
     */
    private with sharing class RollupWrites {

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
