/**
 * The Phase 5 DERIVED half: what the server writes on the `Transaction__c` when a checklist item
 * whose whole content is a deal-record update is completed.
 *
 * layer=service. ZERO inline SOQL - the one read is
 * `ChecklistItemSelector.selectForOutcomeByIds`. ZERO subject parsing - every decision is keyed on
 * the coordinate `(Checklist__r.Group_Letter__c, Sequence__c)` through
 * `ChecklistCaptureDefProvider`.
 *
 * TWO COORDINATES ARE DERIVED, and both were chosen because the item's own subject text says the
 * item IS a write to the deal record - there is nothing for a user to type that they have not
 * already typed somewhere else:
 *   • A5 "Log critical dates into Salesforce deal record"  -> `CriticalDateService.ensureFor`
 *   • B5 "Update deal record: Earnest Money Sent = Yes"     -> `Earnest_Money_Sent__c` +
 *                                                             `Earnest_Money_Sent_Date__c`
 * And one derivation runs on EVERY completion batch, not just those two:
 *   • `Is_Earnest_At_Risk__c` - see `isEarnestAtRisk` for the condition and the staleness limit.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 A5 CALLS `CriticalDateService` DIRECTLY. IT DOES **NOT** RE-WIRE IT TO `TransactionTrigger`.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `TransactionTriggerHandler.afterUpdate` carries an explicit, dated block recording that the
 * `CriticalDateService` arm was REMOVED by user decision on 2026-09-01 and must not be restored
 * while design GATE-B2 and GATE-B4 are open. That decision is untouched by this class and the
 * handler is not modified by Phase 5 at all.
 *
 * WHY CALLING IT FROM HERE IS NOT THE SAME THING, AND IS NOT A BACKDOOR AROUND THAT GATE. The
 * objection recorded at the removal site is specifically to AUTOMATIC, ORG-WIDE projection: wiring
 * the trigger arm makes every deal in the org project critical dates on its next stage move, and
 * because `Critical_Date__c.Transaction__c` is `required=true` with `deleteConstraint=Restrict`,
 * that makes `DELETE_FAILED` the default for every Transaction in the org and breaks
 * `scripts/seed-transactions.apex` and every scratch rebuild (GATE-B3). None of that follows from
 * this call:
 *   • It fires ONLY when a human completes A5 on ONE deal. It is opt-in per deal, by the person
 *     whose job the step is, and the step is literally titled "Log critical dates into Salesforce
 *     deal record". Refusing to log them when someone ticks that box would make the item a lie.
 *   • The undeletability consequence therefore attaches to deals somebody deliberately logged dates
 *     on, not to every row the org creates.
 *   • GATE-B2 (`Contract Executed` is not a valid `Critical_Date__c.Type__c` value) cannot bite:
 *     `CriticalDateService` writes only `Closing Date`, `Feasibility End` and `Loan Commitment`,
 *     all three of which are valid today. This class passes no type list of its own and must never
 *     gain one.
 *   • GATE-B4 (which record is the source of truth) is likewise unchanged - `CriticalDateService`
 *     PINS every row to the deal's own fields, so the projection cannot disagree with the
 *     `transactionCriticalDates` sidebar that reads those same fields via LDS.
 * ⚠ If the business later answers GATE-B3 by refusing the undeletability, THIS CALL IS IN SCOPE OF
 * THAT ANSWER TOO. It is a smaller blast radius, not a different question.
 *
 * 🔴 AND IT IS NOT A DORMANT ONE. `CriticalDateService`, `TransactionSelector.selectForCriticalDates`
 * and `CriticalDateSelector` all used to record that the "a throw rolls back the user's own save"
 * consequence was DORMANT, because only an operator-run script called the service. This call
 * retires that: `applyForCompletedItems` runs in the SAME TRANSACTION as the user's checklist
 * completion, so anything `ensureFor` throws rolls back their tick.
 *   • MITIGATED for a single bad ROW: `ensureFor` inserts with `allOrNone = false` and logs
 *     per-row failures, so one refused `Critical_Date__c` cannot take the completion down.
 *   • NOT MITIGATED for its two READS, or for an insert that throws outright (a CRUD denial, a
 *     row-lock timeout). Those still surface as a failed checklist completion.
 * That is the correct direction to fail — a user told their tick did not save is better off than
 * one told it did while the dates were silently not logged — but it is a real coupling and the
 * three headers above have been amended to stop describing it as hypothetical.
 *
 * ── WHY THIS IS A SERVICE CALLED FROM `ChecklistItemService`, NOT A TRIGGER ARM ────────────
 * The same reasoning as `ChecklistCaptureService`'s guard, plus one more that is specific:
 * `ChecklistItemTrigger`'s after contexts fire once per 200-row chunk during the fan-out and during
 * any bulk load, and `ChecklistMigrationService` (Phase 4 M1, chunked by
 * `ChecklistMigrationQueueable`) inserts historical items ALREADY
 * COMPLETE. An after-insert outcome arm would therefore fire A5 for every migrated deal in the org
 * on migration day - creating `Critical_Date__c` rows nobody asked for and making those deals
 * undeletable, inside a migration whose whole design premise is that it stays reversible.
 * ⇒ The trigger is not extended. `applyForCompletedItems` is `public` precisely so a migration or a
 * backfill can call it DELIBERATELY, for a chosen set, with its eyes open.
 * ⚠ THE COST OF THAT CHOICE, STATED: a Data Loader or Flow completion of A5/B5 stamps nothing. The
 * same ceiling the wire-evidence guard already has.
 *
 * ── TWO RE-APPLICATION CONTROLS, COVERING TWO DIFFERENT PATHS ──────────────────────────────
 * Both were added 2026-09-02 and NEITHER SUBSTITUTES FOR THE OTHER:
 *   1. `suppressOutcomeApplication(Boolean)` - the INSERT case. There is no `Trigger.oldMap` in an
 *      after-insert context, so a transition test is not merely wrong there, it is not evaluable.
 *      A caller replaying history (the migration) declares that it is.
 *   2. The `priorByItemId` argument on `applyForCompletedItems` - the UPDATE case, where prior
 *      state DOES exist. Stops an unrelated edit to an already-complete item from re-applying its
 *      outcomes.
 * 🔴 ORDERING FACT, RECORDED HERE BECAUSE IT RUNS OPPOSITE TO THE USUAL AND WILL NOT BE GUESSED:
 * until control 1 existed, **Phase 4's M1 migration could not safely run in an org where
 * `applyForCompletedItems` was wired into an after context.** M1 was safe only because this class
 * has no trigger caller at all - THE HAZARD ARRIVES WITH THIS PHASE, NOT WITH THE MIGRATION.
 * Anyone adding a trigger arm here later inherits that ordering constraint and must set the flag
 * around the migration's DML, exactly as `ChecklistMigrationService.persist` already brackets its
 * statements with the rollup suppression.
 *
 * ── SHARING AND MODE ───────────────────────────────────────────────────────────────────────
 * `with sharing`, and the `Transaction__c` write is `AccessLevel.SYSTEM_MODE` with NO sharing
 * escalation. Those are two separate decisions and both are argued at `commitDealWrites`.
 *
 * @see force-app/main/default/classes/ChecklistItemService.cls (the caller)
 * @see force-app/main/default/classes/CriticalDateService.cls (A5)
 * @see force-app/main/default/classes/ChecklistCaptureDefProvider.cls (the coordinate map)
 * @see agent-output/design-transaction-fsd-gaps.md §5.7, §5.8
 */
public with sharing class ChecklistOutcomeService {

    /**
     * Deal stages at which the earnest money is no longer at risk because the deal has closed and
     * the deposit has been applied to the purchase price.
     *
     * ⚠ `Post-Closing` IS IN THIS SET AND THAT IS NOT A TYPO. The money is applied AT closing, and
     * `Post-Closing` is after that. `CriticalDateService` draws the same line for the same reason
     * (its `TERMINAL_STAGES` is `{Closed, Post-Closing}`); if one of the two ever moves, the other
     * must move with it or a deal will simultaneously have no upcoming feasibility date and a
     * deposit reported as still at risk.
     */
    @TestVisible
    private static final Set<String> SETTLED_STAGES = new Set<String>{ 'Closed', 'Post-Closing' };

    /** `Transaction__c.Status__c` value meaning the deal is done. */
    @TestVisible
    private static final String STATUS_CLOSED = 'Closed';

    /** Deals whose `Transaction__c` row this run actually wrote. In-context, for test assertions. */
    @TestVisible
    private static Integer lastRunDealWriteCount = 0;

    /** Deals this run handed to `CriticalDateService`. In-context, for test assertions. */
    @TestVisible
    private static Integer lastRunCriticalDateDealCount = 0;

    /**
     * Items the outcome read actually returned - i.e. the ones this run genuinely considered.
     *
     * 🔴 THIS IS THE NUMBER A CALLER MUST REPORT AS "APPLIED", NOT THE SIZE OF THE SET IT PASSED IN.
     * See `lastRunUnreadableItemCount` for the failure that distinction prevents.
     */
    @TestVisible
    private static Integer lastRunConsideredItemCount = 0;

    /**
     * Items that were ASKED FOR but which the outcome read did not return at all.
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THIS IS THE **NATURAL** SHARING FAILURE, AND IT USED TO BE COMPLETELY UNINSTRUMENTED.
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * `lastRunUnresolvedDealCount` below counts a row whose `Transaction__r` came back NULL - and
     * `selectForOutcomeByIds`'s own header says that state CANNOT ARISE naturally, because
     * `Checklist_Item__c` is `ControlledByParent`: a principal who cannot see the deal cannot see
     * the item either. So the counter that existed watched the impossible case.
     * WHAT ACTUALLY HAPPENS is that the read returns FEWER ROWS, or NONE - and the method then
     * returned silently at the `items.isEmpty()` guard with every counter at zero and
     * `lastRunSuppressed = false`, which is indistinguishable from "ran and found nothing to do".
     * `scripts/backfill-checklist-outcomes.apex` then added `chunk.size()` to its applied total and
     * logged success. That is precisely the "silent no-op that logs success while the cutover KPI
     * stays at zero" failure the no-prior overload exists to prevent, reached through the other
     * door.
     * ⚠ NOT INCREMENTED WHEN `outcomeRowsOverride` IS SET - the seam supplies rows directly, so
     * `itemIds` and the row list are unrelated there and a diff would be meaningless noise.
     */
    @TestVisible
    private static Integer lastRunUnreadableItemCount = 0;

    /**
     * Deals skipped because the SYSTEM_MODE spanning read could not see the parent Transaction.
     * 🔴 A NON-ZERO VALUE HERE IS A SHARING PROBLEM, NOT A DATA PROBLEM. See `applyForCompletedItems`.
     */
    @TestVisible
    private static Integer lastRunUnresolvedDealCount = 0;

    /** Items skipped by the transition gate because they were ALREADY done. In-context. */
    @TestVisible
    private static Integer lastRunAlreadyDoneCount = 0;

    /**
     * Whether the last run returned early because outcome application was suppressed.
     * ⚠ Distinguishes "suppressed" from "ran and found nothing", which are indistinguishable from
     * the three counters above - both leave all of them at zero.
     */
    @TestVisible
    private static Boolean lastRunSuppressed = false;

    /**
     * TEST-ONLY fault-injection seam for the outcome read.
     *
     * 🔴 IT EXISTS FOR EXACTLY ONE BRANCH THAT CANNOT OTHERWISE BE REACHED: the fail-closed skip
     * when the SYSTEM_MODE spanning read returns a null parent `Transaction__r`. That state is
     * produced by SHARING, not by data — `Checklist_Item__c` is `ControlledByParent`, so a
     * principal who cannot see the deal cannot see the item either and the read returns no row at
     * all rather than a row with null spans. Only a caller that is NOT the completing user (a
     * future migration batch, a Schedulable) can produce it, and neither exists yet.
     *
     * ⚠ A SEAM THAT ONLY EVER RETURNS NOTHING WOULD PASS ITS OWN TEST VACUOUSLY.
     * `ChecklistOutcomeServiceTest` therefore pairs the fault case with a PRESENCE CONTROL that
     * feeds a fully resolvable row through the same seam and asserts the outcome IS applied.
     *
     * PRECEDENT: `ChecklistFanoutService.taskDefsOverride`.
     */
    @TestVisible
    private static List<Checklist_Item__c> outcomeRowsOverride;

    /**
     * 🔴 THE MIGRATION RE-ENTRANCY SWITCH. Mirrors `ChecklistRollupService.suppressTriggerRecalc`,
     * which exists for the same class of reason on the fan-out path.
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * WHY A SUPPRESSION FLAG AND NOT (ONLY) A TRANSITION TEST — THE ARGUMENT IS DECISIVE.
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * `ChecklistMigrationService` INSERTS `Checklist_Item__c` rows that are ALREADY `Completed`,
     * carrying legacy history forward. **There is no `Trigger.oldMap` in an after-INSERT context**,
     * so a transition test cannot be evaluated there at all - it would have to answer "is a row
     * created already-done a transition?" with one fixed answer, and BOTH answers are wrong:
     *   • NO  -> a legitimate Data Loader or API insert of a completed item silently never applies
     *            its outcomes, forever, with no error.
     *   • YES -> the migration re-applies every outcome on every migrated deal, inside the very
     *            transaction whose whole design premise is that it stays cheaply reversible.
     * A caller-declared suppression answers it without guessing: the migration KNOWS it is
     * replaying history rather than making it, and says so.
     *
     * ⚠ THIS DOES NOT MAKE THE OUTCOMES OPTIONAL FOR MIGRATED DEALS - IT DEFERS THEM.
     * `scripts/backfill-checklist-outcomes.apex` is the deliberate post-M1 path and runs WITHOUT
     * the flag, after M1's reconciliation report has gated the cutover. Suppressing here and
     * backfilling there is the whole point: it keeps the `Critical_Date__c` rows (and therefore the
     * permanent undeletability they impose) out of the migration transaction.
     *
     * ⚠ O(1) AND CHECKED ONCE. `applyForCompletedItems` reads it before ANY SOQL or DML and never
     * inside a loop, so suppression costs nothing at any row count. A static dies with the
     * transaction, so a failed migration chunk cannot leak it forward into the next one.
     */
    private static Boolean outcomeApplicationSuppressed = false;

    /**
     * Turns the migration re-entrancy switch on or off.
     *
     * ⚠ ALWAYS RESTORE THE PRIOR VALUE IN A `finally`, never blindly set false. The same hazard
     * `ChecklistRollupService.suppressTriggerRecalc` documents applies here: a nested caller that
     * resets unconditionally would re-arm outcome application halfway through an outer scope's DML.
     *
     * @param suppressed true to make `applyForCompletedItems` a no-op.
     * @example
     * Boolean prior = ChecklistOutcomeService.isOutcomeApplicationSuppressed();
     * try { ChecklistOutcomeService.suppressOutcomeApplication(true); ... }
     * finally { ChecklistOutcomeService.suppressOutcomeApplication(prior); }
     */
    public static void suppressOutcomeApplication(Boolean suppressed) {
        outcomeApplicationSuppressed = (suppressed == true);
    }

    /**
     * @return true when outcome application is currently suppressed.
     */
    public static Boolean isOutcomeApplicationSuppressed() {
        return outcomeApplicationSuppressed;
    }

    /**
     * Items the LAST run actually read and considered.
     *
     * 🔴 PUBLIC BECAUSE ANONYMOUS APEX CANNOT READ A `@TestVisible private static`, AND
     * `scripts/backfill-checklist-outcomes.apex` MUST REPORT THIS RATHER THAN THE SIZE OF THE SET
     * IT PASSED IN. Counting the input as "applied" reports success for items the read never
     * returned - the exact silent-success failure this pair of counters exists to expose.
     *
     * @return the number of items the last `applyForCompletedItems` call resolved; 0 when it was
     *         suppressed, short-circuited, or read nothing.
     */
    public static Integer lastRunConsideredItems() {
        return lastRunConsideredItemCount;
    }

    /**
     * Items the LAST run was asked for but could not read.
     *
     * 🔴 A NON-ZERO VALUE IS A SHARING OR VISIBILITY PROBLEM AND MUST BE SURFACED, NOT SUMMED AWAY.
     * On a backfill it means those items were skipped while the run otherwise looked healthy.
     *
     * @return the shortfall between the ids passed in and the rows read; always 0 when the test
     *         seam is supplying rows.
     */
    public static Integer lastRunUnreadableItems() {
        return lastRunUnreadableItemCount;
    }

    /**
     * Applies every derived outcome the supplied completed items imply, and refreshes
     * `Is_Earnest_At_Risk__c` on each of their deals.
     *
     * 🔴 CALLED **AFTER** THE COMPLETION DML HAS COMMITTED, NOT BEFORE. The outcome of completing
     * B5 is only true once B5 is actually complete; running it first would stamp
     * `Earnest_Money_Sent__c` on a save that the wire-fraud gate or a validation rule then refuses,
     * and the two writes are in the same transaction so the stamp would roll back with it - but the
     * ORDER still matters for the DERIVED reads, which must see the committed item state.
     *
     * ⚠ FAILS CLOSED PER DEAL, NOT PER BATCH. An item whose parent Transaction cannot be resolved
     * through the SYSTEM_MODE spanning read is SKIPPED and counted in
     * `lastRunUnresolvedDealCount`, never computed from the nulls the read returns. This is the one
     * genuinely dangerous failure mode in this class: `SYSTEM_MODE` lifts CRUD and FLS and NEVER
     * sharing, `Transaction__c` is Private OWD, and a sharing-filtered spanning read returns NULL
     * for every traversed field rather than throwing. A null `Feasibility_Deadline__c` reads as
     * "feasibility has not passed", which computes at-risk = FALSE and would CLEAR the flag on
     * exactly the deals the portfolio KPI exists to surface. The `Transaction__r.Id != null` check
     * is what stops an access problem from being laundered into a wrong number.
     *
     * COST: 1 SOQL always; +1 DML only when a value actually changes; +2 SOQL +1 DML only when the
     * batch contains a completed A5 (`CriticalDateService.ensureFor`).
     *
     * ⚠ THE NO-PRIOR OVERLOAD TREATS EVERY DONE ITEM AS NEWLY DONE, AND THAT IS LOAD-BEARING
     * RATHER THAN A DEFAULT NOBODY THOUGHT ABOUT. `scripts/backfill-checklist-outcomes.apex` exists
     * precisely to apply outcomes to items that were completed BEFORE Phase 5 existed. If "already
     * done means skip" were the default, that script would become a silent no-op and the
     * cutover-day portfolio KPI would stay at zero - which is the exact failure it was written to
     * prevent. A caller that CAN see prior state opts into the transition gate by passing it.
     *
     * @param itemIds `Checklist_Item__c` ids that have just been completed; null/empty-safe.
     * @throws System.DmlException on a platform save failure of the deal write.
     * @example
     * ChecklistOutcomeService.applyForCompletedItems(new Set&lt;Id&gt;{ itemId });
     */
    public static void applyForCompletedItems(Set<Id> itemIds) {
        applyForCompletedItems(itemIds, null);
    }

    /**
     * The transition-gated form. Identical to the overload above except that a DERIVED outcome is
     * applied only to an item this save actually moved INTO a done state.
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 WHY THIS EXISTS AS WELL AS THE SUPPRESSION FLAG - TWO CONTROLS, TWO FAILURE MODES.
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * `suppressOutcomeApplication` covers the INSERT case, where no prior state exists to compare
     * against (the migration). This covers the UPDATE case, where it does - and it is a Phase 5
     * defect in its own right, not migration fallout: without it, ANY unrelated edit to an
     * already-complete item re-applies its outcomes. Editing a comment on a completed A5 would
     * re-run `CriticalDateService`; editing one on a completed B5 would re-enter the earnest
     * stamping path. Both outcomes happen to be internally idempotent today (`ensureFor` keys on
     * `(Transaction + Type)`, and the earnest date is stamped only when blank), so nothing visible
     * breaks - but that is defence BY LUCK at the outcome level rather than by design at the
     * dispatch level, and the next derived outcome added here will not be so forgiving.
     * Same belt-and-braces shape as the wire-fraud gate: a trigger control and a rule control,
     * covering different paths, neither relied on to cover the other's.
     *
     * ⚠ THE AT-RISK REFRESH IS **NOT** GATED, DELIBERATELY. `Is_Earnest_At_Risk__c` is a stored
     * checkbox derived from a DATE, and nothing saves a deal on the day its feasibility expires -
     * the whole staleness mitigation is that any checklist activity on the deal refreshes it. Only
     * the DERIVED OUTCOMES (A5 / B5) are transition-gated; every resolvable deal in the batch still
     * gets its flag recomputed. `anOrdinaryCompletionRefreshesAtRiskOnAnAlreadySentDeal` pins that.
     *
     * @param itemIds        `Checklist_Item__c` ids saved by this transaction; null/empty-safe.
     * @param priorByItemId  the items' state BEFORE this save, keyed by Id - for the service path
     *                       this is the `ChecklistItemSelector.selectForCompletion` map, read
     *                       before the DML. NULL means "prior state unknown", which treats every
     *                       done item as newly done (see the overload above).
     * @throws System.DmlException on a platform save failure of the deal write.
     * @example
     * ChecklistOutcomeService.applyForCompletedItems(itemIds, existing);
     */
    public static void applyForCompletedItems(
        Set<Id> itemIds,
        Map<Id, Checklist_Item__c> priorByItemId
    ) {
        lastRunDealWriteCount = 0;
        lastRunCriticalDateDealCount = 0;
        lastRunUnresolvedDealCount = 0;
        lastRunAlreadyDoneCount = 0;
        lastRunConsideredItemCount = 0;
        lastRunUnreadableItemCount = 0;
        lastRunSuppressed = false;
        if (itemIds == null || itemIds.isEmpty()) {
            return;
        }
        // 🔴 BEFORE ANY SOQL OR DML, AND NEVER INSIDE A LOOP. See `outcomeApplicationSuppressed`.
        if (outcomeApplicationSuppressed) {
            lastRunSuppressed = true;
            return;
        }

        List<Checklist_Item__c> items = outcomeRowsOverride != null
            ? outcomeRowsOverride
            : ChecklistItemSelector.selectForOutcomeByIds(itemIds).values();
        lastRunConsideredItemCount = items.size();
        if (outcomeRowsOverride == null && items.size() < itemIds.size()) {
            // 🔴 RECORDED **BEFORE** THE EARLY RETURN BELOW, WHICH IS THE WHOLE POINT. An empty or
            // short read is the natural sharing failure on this path, and without this line it left
            // every counter at zero and was indistinguishable from "nothing to do".
            lastRunUnreadableItemCount = itemIds.size() - items.size();
        }
        if (items.isEmpty()) {
            return;
        }

        // Deals whose earnest money this batch marks as sent, and deals whose critical dates it
        // projects. Both keyed by deal, so two completed B5s on one deal produce one write.
        Set<Id> earnestSentDeals = new Set<Id>();
        Set<Id> criticalDateDeals = new Set<Id>();
        Map<Id, Transaction__c> dealsById = new Map<Id, Transaction__c>();

        for (Checklist_Item__c item : items) {
            Transaction__c deal = dealFor(item);
            if (deal == null) {
                lastRunUnresolvedDealCount++;
                continue;
            }
            dealsById.put(deal.Id, deal);

            if (!ChecklistItemDomain.isDone(item.Flag__c)) {
                // Not actually complete. The deal still gets its at-risk refresh (it is in
                // `dealsById`), but no outcome is applied for an item that is not done.
                continue;
            }
            if (!isTransitionIntoDone(item, priorByItemId)) {
                // Already done BEFORE this save. Same treatment as an incomplete item: the deal
                // still gets its at-risk refresh, but its outcomes are not re-applied.
                lastRunAlreadyDoneCount++;
                continue;
            }
            ChecklistCaptureDefProvider.CaptureDef def = ChecklistCaptureDefProvider.forCoordinate(
                item.Checklist__r == null ? null : item.Checklist__r.Group_Letter__c,
                item.Sequence__c
            );
            if (def == null
                    || def.captureMode != ChecklistCaptureDefProvider.CaptureMode.DERIVED) {
                continue;
            }
            if (def.derivedOutcome == ChecklistCaptureDefProvider.DerivedOutcome.EARNEST_MONEY_SENT) {
                earnestSentDeals.add(deal.Id);
            } else if (def.derivedOutcome
                    == ChecklistCaptureDefProvider.DerivedOutcome.CRITICAL_DATES) {
                criticalDateDeals.add(deal.Id);
            }
        }

        commitDealWrites(buildDealWrites(dealsById, earnestSentDeals));

        if (!criticalDateDeals.isEmpty()) {
            lastRunCriticalDateDealCount = criticalDateDeals.size();
            // Idempotent and self-healing on its own key (Transaction + Type), so completing A5 on
            // a deal that already has its dates creates nothing and throws nothing.
            CriticalDateService.ensureFor(criticalDateDeals);
        }
    }

    /**
     * Builds the sparse `Transaction__c` rows this run needs to write.
     *
     * 🔴 THE AT-RISK DERIVATION USES THE **PENDING** `Earnest_Money_Sent__c`, NOT THE QUERIED ONE,
     * AND GETTING THAT WRONG WOULD MAKE B5 SILENTLY USELESS. When a completed B5 is in the batch,
     * the deal read a moment ago still says `Earnest_Money_Sent__c = false`; this method is about to
     * set it true. Computing at-risk from the queried value would evaluate the flag against the
     * state BEFORE the write in the very transaction that changes it, so a deal whose feasibility
     * had already expired would be marked "money sent" and "not at risk" in one save, and would
     * stay wrong until something else happened to touch it.
     *
     * ⚠ A ROW IS ONLY ADDED WHEN A FIELD ACTUALLY CHANGES. Every checklist completion calls this
     * method, and a no-op `Transaction__c` update on every tick would fire `TransactionTrigger` and
     * `DealTransactionGateService` for nothing, on an object whose handler header promises that
     * counter-only writes cost zero.
     *
     * ⚠ `Earnest_Money_Sent_Date__c` IS STAMPED ONLY WHEN IT IS BLANK. A second completion of B5
     * (or a deliberate re-run of `applyForCompletedItems` from a backfill) must not overwrite the
     * date the wire actually went out with today. `Earnest_Money_Sent__c` is idempotent by nature.
     *
     * ⚠ `EM_Wired_Date__c` IS NOT TOUCHED AND MUST NOT BE. It is a separate, pre-existing field
     * that `lwc/transactionCriticalDates` already reads, and `Earnest_Money_Sent_Date__c`'s own
     * field XML records that conflating the two is a separate business decision with its own
     * backfill. `EM_Wired__c` cannot be written at all - it is a formula TEXT field rendering
     * `Earnest_Money__c` as a display string such as `$1.5M`.
     *
     * @param dealsById        deals resolved from the batch, as read.
     * @param earnestSentDeals deals whose B5 this batch completed.
     * @return sparse rows to update; empty when nothing changed.
     */
    @TestVisible
    private static List<Transaction__c> buildDealWrites(
        Map<Id, Transaction__c> dealsById,
        Set<Id> earnestSentDeals
    ) {
        List<Transaction__c> writes = new List<Transaction__c>();
        // Hoisted so a batch spanning midnight cannot evaluate two deals against two different
        // days, and so 200 deals make one call rather than 200.
        Date today = Date.today();

        for (Transaction__c deal : dealsById.values()) {
            Boolean stampEarnest = earnestSentDeals.contains(deal.Id)
                && deal.Earnest_Money_Sent__c != true;
            Boolean stampEarnestDate = earnestSentDeals.contains(deal.Id)
                && deal.Earnest_Money_Sent_Date__c == null;

            // THE PENDING VALUE. See the header of this method.
            Boolean sentAfterThisSave = earnestSentDeals.contains(deal.Id)
                || deal.Earnest_Money_Sent__c == true;

            Boolean atRisk = isEarnestAtRisk(
                sentAfterThisSave,
                deal.Feasibility_Deadline__c,
                deal.Feasibility_Missed__c,
                deal.Status__c,
                deal.Stage__c,
                today
            );
            Boolean flipRisk = deal.Is_Earnest_At_Risk__c != atRisk;

            if (!stampEarnest && !stampEarnestDate && !flipRisk) {
                continue;
            }
            Transaction__c write = new Transaction__c(Id = deal.Id);
            if (stampEarnest) {
                write.Earnest_Money_Sent__c = true;
            }
            if (stampEarnestDate) {
                write.Earnest_Money_Sent_Date__c = today;
            }
            if (flipRisk) {
                write.Is_Earnest_At_Risk__c = atRisk;
            }
            writes.add(write);
        }
        return writes;
    }

    /**
     * 🔴 THE EARNEST-AT-RISK CONDITION. THE SINGLE DEFINITION - DO NOT RE-DERIVE IT ANYWHERE ELSE.
     *
     * A pure function: no SOQL, no DML, no `Date.today()` (the caller supplies the day, so a test
     * can pin one and a 200-row batch cannot straddle midnight).
     *
     * `Is_Earnest_At_Risk__c` means "the deposit is no longer refundable". Three conditions, all
     * required:
     *
     *   1. THE MONEY IS ACTUALLY OUT THE DOOR (`Earnest_Money_Sent__c`). A deposit that has not been
     *      wired cannot be at risk, however far the calendar has run. This is the B5 stamp above.
     *      ⚠ `EM_Wired__c` IS NOT USABLE HERE - it is a formula TEXT field rendering
     *      `Earnest_Money__c` as `$1.5M`, so it is neither boolean nor writable. `EM_Wired_Date__c`
     *      is a different pre-existing field which the business has not confirmed is the same event.
     *
     *   2. THE FEASIBILITY PERIOD HAS ENDED. This is the CRE meaning of "goes hard": during the
     *      feasibility / due-diligence window the buyer may terminate and recover the deposit; once
     *      it expires without termination, they cannot. Two ways to be past it, joined by OR:
     *        (a) `Feasibility_Deadline__c < today`, and
     *        (b) `Feasibility_Missed__c = true`.
     *      🔴 (b) IS CORROBORATING, NOT EXCULPATORY, AND THIS INVERTS design §5.8's PARENTHETICAL.
     *      That section proposes `Feasibility_Deadline__c < TODAY && Earnest_Money_Sent__c` "(and
     *      not `Feasibility_Missed__c`)". Excluding missed-feasibility deals is backwards: a deal
     *      that blew through its feasibility deadline is the MOST at-risk case there is, and
     *      excluding it would zero the portfolio KPI on precisely the deals it exists to surface.
     *      `CriticalDateService` treats the same flag as proof the period is over - it drops the
     *      `Feasibility End` critical date when it is set, because "a future feasibility end on a
     *      deal that already missed feasibility is a contradiction". The OR also covers a deal with
     *      NO recorded deadline that is nonetheless known to have missed it, which the AND form
     *      could never reach.
     *
     *   3. THE DEAL HAS NOT SETTLED. At closing the deposit is applied to the purchase price, so it
     *      stops being at risk and starts being part of the consideration. `Status__c = 'Closed'`,
     *      `Stage__c = 'Closed'` or `Stage__c = 'Post-Closing'` all mean that.
     *      ⚠ THE PORTFOLIO KPI ALREADY FILTERS TO `Status__c = 'Active'`
     *      (`TransactionController.getKpis`), so this third condition changes nothing there. It is
     *      here for the RECORD PAGE: `lwc/transactionCriticalDates` renders the flag beside the
     *      earnest-money row with no status filter at all, and a closed deal showing "at risk" is
     *      wrong on the one screen a human actually reads.
     *
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE HONEST LIMITATION: THIS IS A STORED CHECKBOX, SO IT CAN BE STALE BY A FEW DAYS.
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * Nothing saves a Transaction on the day its feasibility deadline passes, so the flag is only
     * correct as of the last time something recomputed it. Recomputation happens on EVERY checklist
     * completion on the deal (this class runs on every batch, not only on A5/B5), which on a live
     * deal is most working days - but it is not "at midnight".
     *
     * design §5.8 and OQ-5 recommend converting the field to a FORMULA, which would be
     * self-maintaining and need no job. **THAT CONVERSION IS BLOCKED TODAY, AND THE BLOCKER IS NOT
     * A JUDGEMENT CALL:**
     *   • `DPEG_Transaction_Edit.permissionset-meta.xml:61` grants `Is_Earnest_At_Risk__c` with
     *     `editable=true`. `editable=true` on a formula field FAILS THE DEPLOY, so the conversion
     *     requires editing that permission set - and `DPEG_Transaction_Edit` is one of the files a
     *     concurrent session owns and this phase must not touch.
     *   • Ten seed-script statements ASSIGN the field
     *     (`scripts/seed-transactions.apex:48,55,62,69,92` and the non-destructive twin), and a
     *     formula field is not writable, so all ten stop compiling. That is the same "converting a
     *     stored Number to a roll-up is a suite-wide compile break" argument design §5.3 makes and
     *     accepts for `Tasks_Complete__c`.
     * ⇒ It stays a stored checkbox for now, written here. A Schedulable was the other option and was
     *   not built: this org already carries two unscheduled jobs as open go-live gates, and a third
     *   that silently never runs is worse than a flag that is a few days behind.
     *
     * @param earnestMoneySent    the deal's `Earnest_Money_Sent__c` AS IT WILL BE after this save.
     * @param feasibilityDeadline `Feasibility_Deadline__c`; null-safe.
     * @param feasibilityMissed   `Feasibility_Missed__c`; null-safe (null is treated as false).
     * @param status              `Status__c`; null-safe.
     * @param stage               `Stage__c`; null-safe.
     * @param today               the day to evaluate against; supplied so it can be pinned.
     * @return true when the deposit is non-refundable and the deal has not settled.
     * @example
     * Boolean atRisk = ChecklistOutcomeService.isEarnestAtRisk(
     *     true, Date.today().addDays(-1), false, 'Active', 'Due Diligence', Date.today());
     */
    public static Boolean isEarnestAtRisk(
        Boolean earnestMoneySent,
        Date feasibilityDeadline,
        Boolean feasibilityMissed,
        String status,
        String stage,
        Date today
    ) {
        if (earnestMoneySent != true) {
            return false;
        }
        if (STATUS_CLOSED.equals(status) || SETTLED_STAGES.contains(stage)) {
            return false;
        }
        if (feasibilityMissed == true) {
            return true;
        }
        return feasibilityDeadline != null && today != null && feasibilityDeadline < today;
    }

    /**
     * Persists the deal writes.
     *
     * 🔴 `AccessLevel.SYSTEM_MODE`, AND IT IS A CRUD DECISION, NOT A SHARING ONE. THE TWO QUESTIONS
     * ARE ASKED SEPARATELY BECAUSE SYSTEM_MODE ANSWERS ONLY THE FIRST.
     *
     * THE CRUD HALF, RESTATED 2026-09-02 BECAUSE THE FIRST VERSION OVERSTATED IT.
     * It said this write "would be refused for exactly the principals the feature is for". That is
     * NOT true under the documented assignment model and the claim is withdrawn:
     * `DPEG_Transaction_Team` holds BOTH `DPEG_Transaction_Edit` and `DPEG_Checklist_Edit`
     * (verified 2026-09-02, lines 7 and 9 of the group), permission sets are ADDITIVE, and
     * `DPEG_Transaction_Edit:59-63` grants `Is_Earnest_At_Risk__c` with `editable=true`. A member of
     * that group would pass a `USER_MODE` write.
     *
     * ⚠ THAT IS EXACTLY WHY THE PSG UNION IS THE WRONG THING TO REASON FROM. What a principal
     * happens to hold today is an assignment fact, not a contract, and this repo has already been
     * caught reading a group union as though it were a per-set grant. The mode is decided by the
     * two things that ARE contracts:
     *   1. `DPEG_Checklist_Edit` grants `allowEdit=false` on `Transaction__c` and grants
     *      `Is_Earnest_At_Risk__c` NOT AT ALL (neither checklist set carries the field). That set
     *      exists precisely so somebody can be given the checklist without the deal record, which
     *      is a legitimate least-privilege shape. A principal in that shape would have their
     *      completion saved and THEN be refused here — a half-applied outcome with a platform error
     *      on top of it.
     *   2. ARCHITECTURE.md §2's actual discriminator, which needs no permission set at all: this is
     *      a write performed ON the principal's behalf. They asked to tick a checklist item; they
     *      did not ask to stamp `Is_Earnest_At_Risk__c`, and they cannot act on a refusal of it.
     *      A read or write the user did not request is the automation case, and automation paths
     *      use SYSTEM_MODE.
     * ⇒ The mode stands. Only the argument for it changed.
     *
     * ✅ THE SHARING HALF NEEDS NO ESCALATION, AND THIS CLASS DELIBERATELY DOES **NOT** COPY
     * `ChecklistRollupService.RollupWrites`'s `without sharing` INNER CLASS. That escalation exists
     * for a reason its own header now records as VOID - it was argued from an inverted reading of
     * `writeRequiresMasterRead`. The correct fact is the opposite and it works in this class's
     * favour: `writeRequiresMasterRead=false` is the STRICTER setting, requiring read AND write on
     * the master, and both master-detail links in the chain carry it. So a user who has just
     * updated a `Checklist_Item__c` provably holds EDIT-level sharing on the `Transaction__c` two
     * hops above it, or the platform would have refused their completion before this code ran.
     * ⚠ THAT ARGUMENT IS ABOUT THE COMPLETION PATH AND ONLY THE COMPLETION PATH. A future migration
     * batch or Schedulable calling `applyForCompletedItems` as a service principal with no deal
     * sharing would be silently filtered - which is why the spanning read is discriminated on
     * `Transaction__r.Id` and skipped deals are COUNTED rather than assumed away.
     *
     * ⚠ `allOrNone = true`. A partial success would leave `Earnest_Money_Sent__c` set on some deals
     * and not others with no error anywhere, and the caller's completion would still report success.
     * The 2026-09-02 correction in `ChecklistRollupService` records the same failure shape from
     * `allOrNone = false` on a parent write.
     *
     * @param writes sparse `Transaction__c` rows; null/empty-safe.
     * @throws System.DmlException on a platform save failure.
     */
    private static void commitDealWrites(List<Transaction__c> writes) {
        if (writes == null || writes.isEmpty()) {
            return;
        }
        lastRunDealWriteCount = writes.size();
        Database.update(writes, true, AccessLevel.SYSTEM_MODE);
    }

    /**
     * Whether THIS SAVE moved the item into a done state, as opposed to the item having already
     * been done when the save started.
     *
     * 🔴 A MISSING KEY MEANS "TREAT IT AS A TRANSITION", AND THAT IS THE SAFE DIRECTION HERE -
     * WHICH IS THE OPPOSITE OF THE FAIL-CLOSED RULE ELSEWHERE IN THIS FILE, SO IT IS ARGUED RATHER
     * THAN ASSUMED. Everywhere else an unresolved lookup means "refuse", because the alternative is
     * writing something wrong. Here the alternative is *skipping* a legitimate outcome, and the two
     * costs are not symmetric:
     *   • Treating a genuine re-save as a transition re-runs an outcome that is idempotent today
     *     (`ensureFor` keys on `(Transaction + Type)`; the earnest date is stamped only when blank).
     *   • Treating a genuine completion as a re-save means B5 never stamps and A5 never projects,
     *     silently, forever, with a green save and no error anywhere.
     * The second is the RISK-1 failure shape. So an absent prior resolves toward applying.
     * ⚠ A caller that wants the strict reading must pass a prior map that covers every id it
     * passes. `ChecklistItemService` does: its map comes from the same `selectForCompletion` read
     * that produced the ids.
     *
     * @param item          the item as saved.
     * @param priorByItemId prior state keyed by Id, or null when unknown.
     * @return true when the item is newly done, or when prior state is unavailable.
     */
    @TestVisible
    private static Boolean isTransitionIntoDone(
        Checklist_Item__c item,
        Map<Id, Checklist_Item__c> priorByItemId
    ) {
        if (priorByItemId == null || item == null || item.Id == null) {
            return true;
        }
        Checklist_Item__c prior = priorByItemId.get(item.Id);
        if (prior == null) {
            return true;
        }
        return !ChecklistItemDomain.isDone(prior.Flag__c);
    }

    /**
     * The parent deal of an item, or NULL when the spanning read could not see it.
     *
     * ⚠ THE DISCRIMINATOR IS `Transaction__r.Id`, NOT `Transaction__c`. The lookup FIELD is always
     * populated; it is the TRAVERSED record that a sharing filter empties. Testing the field would
     * pass on exactly the rows this check exists to reject.
     *
     * @param item a row from `ChecklistItemSelector.selectForOutcomeByIds`.
     * @return the parent `Transaction__c` with its outcome fields populated, or null.
     */
    private static Transaction__c dealFor(Checklist_Item__c item) {
        if (item == null || item.Checklist__r == null || item.Checklist__r.Transaction__r == null) {
            return null;
        }
        return item.Checklist__r.Transaction__r;
    }
}
