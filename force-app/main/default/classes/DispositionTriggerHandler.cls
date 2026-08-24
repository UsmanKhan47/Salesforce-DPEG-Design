/**
 * Trigger handler for Disposition__c. Routes four contexts to FOUR services (⚠ this line said
 * "THREE services" until 2026-08-24; corrected in place — the fourth is the BOV re-ranking hook,
 * and it is the only one wired to a SINGLE context):
 *
 *   before insert / before update  -> DispositionStageEntryService.stampListingDates
 *                                        (in-memory, no DML)
 *                                  -> DispositionBrokerStampService.stampSelectedBrokerLabel
 *                                        (in-memory, no DML; off-market broker lookup, 2026-08-20)
 *   after insert  / after update   -> DispositionStageEntryService.createStageEntryRecords
 *                                        (the four child auto-creates)
 *                                  -> DispositionApprovalAdvanceService.enqueuePendingAdvances
 *                                        (the D-1 approval semaphore, added 2026-08-19)
 *   after update ONLY              -> BovAutoSelectionService.reselectForRepricedDispositions
 *                                        (re-rank the BOV submissions when Asking_Price__c
 *                                         changes, added 2026-08-24 — see afterUpdate below for
 *                                         why it is NOT in `route`)
 *
 * The Opportunity twin (OpportunityReviewTriggerHandler) is the shape this copies, including its
 * "old-map on update, null on insert" convention: the SERVICE decides what each context means, so
 * the handler stays a router with no rules of its own.
 *
 * ── 🔴 TWO SERVICES ON THE AFTER CONTEXT, AND THE ORDER IS NOT ARBITRARY ────
 * `createStageEntryRecords` runs FIRST and `enqueuePendingAdvances` SECOND. The stage-entry service
 * performs SYNCHRONOUS DML (it opens the NDA / LOI / PSA / listing children for the stage the
 * record is on NOW); the advance service only ENQUEUES, and the job it enqueues runs after this
 * whole transaction commits. So the order below cannot change what either one does — but it is
 * fixed anyway so that a future reader is not left wondering whether it can, and so an exception
 * from the child creates (which is `allOrNone = true` and WILL roll the transaction back) is not
 * preceded by an enqueue that would then be discarded silently.
 *
 * ⚠ THE TWO HOOKS ANSWER DIFFERENT QUESTIONS ABOUT THE SAME SAVE. Stage entry asks "did the STAGE
 * change into a target value?"; the advance hook asks "did the SEMAPHORE go false -> true?". An
 * approval's `finalApprovalActions` field update changes ONLY the semaphore, so stage entry no-ops
 * on it; the Queueable's own write then changes the stage, so stage entry fires on THAT save
 * instead — which is exactly how an off-market disposition advanced to `NDA` by approval still gets
 * its buyer NDA created. The two hooks are complementary, not redundant.
 *
 * ── ⚠ WHY BOTH BEFORE AND AFTER, AND WHY THE SPLIT IS NOT ARBITRARY ─────────
 * AFTER is required for every CHILD insert: a child needs the parent's Id, which does not exist
 * until after insert.
 *
 * BEFORE is required for the one thing that is NOT a child — `Listing_Date__c`, a field on the
 * Disposition itself. Writing it after the save would mean a SECOND DML against a record that
 * three approval processes lock (`recordEditability = AdminOnly` on all three), which is the
 * ENTITY_IS_LOCKED shape that produced `DispositionNdaStampQueueable` — and a Queueable does not
 * fix it here (D20/W1). Setting it in `before` makes it part of the save the user was already
 * permitted to make, so no lock can refuse it. Full argument at
 * `DispositionStageEntryService.stampListingDates`.
 *
 * ⚠ THE VALUE IS WHAT DECIDES THE CONTEXT, NOT THE OBJECT. `Primary_NDA__c` is also a field on
 * `Disposition__c` and CANNOT move to the before context: its value is the child NDA's Id, which
 * does not exist until after the insert. `Listing_Date__c` depends on nothing but the transition
 * being made, which is fully known in before-update. Do not "harmonise" the two.
 *
 * ── ⚠ TWO SERVICES ON THE BEFORE CONTEXT TOO SINCE 2026-08-20, AND HERE THE ORDER CARRIES NO
 *      MEANING — WHICH IS ITSELF WORTH STATING ──────────────────────────────
 * `stampSelectedBrokerLabel` joins `stampListingDates` in before insert / before update for the SAME
 * reason the latter is there: `Selected_Broker__c` is a field on the Disposition itself, and writing
 * it after the save would be a SECOND DML against a record that three approval processes lock
 * (`recordEditability = AdminOnly` on all three). Its full argument is in that service's header.
 *
 * The two before-context calls write DISJOINT fields (`Listing_Date__c` vs `Selected_Broker__c`) and
 * neither reads the other's output, so unlike the after-context pair their order is genuinely
 * arbitrary. It is said out loud so nobody spends time "fixing" a sequence that means nothing — and
 * so that if a future stamp ever DOES depend on another, whoever adds it knows this paragraph is the
 * thing they have to change.
 *
 * ⚠ NEITHER BEFORE-CONTEXT CALL COSTS SOQL OR DML AT ANY RECORD COUNT — `stampListingDates` issues
 * no statements at all, and `stampSelectedBrokerLabel` issues AT MOST ONE query per chunk and zero
 * on the common case where no record changed its broker. Adding them did not move this trigger's
 * governor budget.
 *
 * ── INSERT AS WELL AS UPDATE, IN BOTH HALVES ────────────────────────────────
 * A Disposition__c can legitimately be CREATED at a target stage: DispositionService.findOrCreate
 * always creates at Disposition Readiness, but the seed scripts and several test surfaces create
 * rows directly at later stages, and All_NDAs_Signed_Before_Progression is ISCHANGED-only
 * precisely so they can. Handling insert costs one extra routed call and removes a class of "the
 * child exists on records made one way and not the other" defect.
 *
 * ── WHY THERE IS NO RECURSION FLAG ──────────────────────────────────────────
 * The service's own DML re-enters this handler twice — once via DispositionNdaStampQueueable's
 * parent stamp, and once if anything else edits the row — and both re-entries no-op because the
 * service fires only on a stage CHANGE INTO a target stage. The stamp update changes
 * Primary_NDA__c and nothing else, so priorStage == newStage. The idempotency read is the second,
 * independent guard. A static boolean would add a third mechanism whose failure mode (a flag left
 * true across a batch chunk silently disabling auto-create for the rest of the transaction) is
 * worse than the problem it solves.
 *
 * ⚠ NEITHER before-context stamp adds recursion risk, and they reach that conclusion by DIFFERENT
 * routes — do not collapse them into one sentence. An in-memory assignment during a save fires no
 * additional trigger, which covers both. Beyond that: `stampListingDates` is FILL-IF-BLANK, so a
 * re-save that did re-enter would find the value already set and change nothing;
 * `stampSelectedBrokerLabel` is CHANGE-KEYED and is not fill-if-blank at all (it must be able to
 * OVERWRITE a stale name when the broker changes, and to CLEAR it when the broker is removed), so
 * its idempotency comes from the fact that `Broker__c` did not change on any re-entrant save. A
 * fill-if-blank broker stamp would be a bug, not a safeguard.
 *
 * 🔴 AND THE 2026-08-19 SEMAPHORE HOOK ADDS NONE EITHER, FOR A THIRD, INDEPENDENT REASON. The
 * Queueable it enqueues writes the stage AND clears `Approval_Advance_Pending__c` in one statement,
 * i.e. true -> false — the OPPOSITE of the false -> true transition the hook detects. The
 * enqueue-loop a naive "the flag is true" test would produce is structurally unreachable, which is
 * why the hook tests the TRANSITION and not the VALUE. See
 * `DispositionApprovalAdvanceService.enqueuePendingAdvances`.
 *
 * @see force-app/main/default/classes/DispositionStageEntryService.cls (the stage-entry logic)
 * @see force-app/main/default/classes/DispositionBrokerStampService.cls (the broker label stamp)
 * @see force-app/main/default/classes/DispositionApprovalAdvanceService.cls (the semaphore logic)
 * @see force-app/main/default/classes/OpportunityReviewTriggerHandler.cls (the acquisitions twin)
 */
public with sharing class DispositionTriggerHandler extends TriggerHandler {

    protected override void beforeInsert() {
        DispositionStageEntryService.stampListingDates((List<Disposition__c>) newList, null);
        DispositionBrokerStampService.stampSelectedBrokerLabel(
            (List<Disposition__c>) newList,
            null
        );
    }

    protected override void beforeUpdate() {
        DispositionStageEntryService.stampListingDates(
            (List<Disposition__c>) newList,
            (Map<Id, Disposition__c>) oldMap
        );
        DispositionBrokerStampService.stampSelectedBrokerLabel(
            (List<Disposition__c>) newList,
            (Map<Id, Disposition__c>) oldMap
        );
    }

    protected override void afterInsert() {
        route((List<Disposition__c>) newList, null);
    }

    /**
     * ── ⚠ A THIRD SERVICE ON THE AFTER-UPDATE CONTEXT SINCE 2026-08-24, AND IT IS ON **UPDATE
     *      ONLY** — WHICH IS WHY IT IS NOT IN `route` ──────────────────────────
     * `BovAutoSelectionService.reselectForRepricedDispositions` re-ranks a sale's BOV submissions
     * when its `Asking_Price__c` changes. `route` is shared with `afterInsert`, and this job has
     * nothing to do there: a Disposition has NO BOV children at the moment it is created, so an
     * insert-context call would query for rows that cannot exist. Putting it here rather than in
     * `route` is what keeps that true by construction instead of by an `if`.
     *
     * 🔴 IT IS MANDATORY, NOT A NICETY. `BOV_Score__c` is PARENT-DERIVED — its 50-point Value term
     * is `BOV_Amount__c / Disposition__r.Asking_Price__c` — so on a sale priced AFTER its BOV
     * responses arrived, EVERY child's score materialises in ONE PARENT SAVE with ZERO child DML.
     * Without this hook no broker is ever auto-appointed on such a sale, and there is no error
     * anywhere: the deploy is green, the tests are green, and UAT reports "it doesn't work". On the
     * evidence (no disposition in the org carried an asking price when the formula was built) that
     * is the PRIMARY path, not an edge case.
     *
     * ⚠ IT COSTS ZERO QUERIES AND ZERO DML UNLESS `Asking_Price__c` ACTUALLY CHANGED — the same
     * "an ordinary Disposition save costs nothing" contract both other hooks already carry, so
     * adding it did not move this trigger's governor budget.
     *
     * ⚠ ORDER: it runs LAST, after `route`. `createStageEntryRecords` is `allOrNone = true` and
     * WILL roll the transaction back on failure, and auto-selection's own write is `allOrNone = true`
     * too; running the child auto-creates first keeps the more consequential failure the earlier
     * one. The two touch disjoint objects and neither reads the other's output, so nothing else
     * depends on the sequence.
     */
    protected override void afterUpdate() {
        route((List<Disposition__c>) newList, (Map<Id, Disposition__c>) oldMap);
        BovAutoSelectionService.reselectForRepricedDispositions(
            (List<Disposition__c>) newList,
            (Map<Id, Disposition__c>) oldMap
        );
    }

    /**
     * @param dispositions The Dispositions in the current trigger context.
     * @param priorById    The old-map on update; null on insert.
     */
    private void route(List<Disposition__c> dispositions, Map<Id, Disposition__c> priorById) {
        DispositionStageEntryService.createStageEntryRecords(dispositions, priorById);
        DispositionApprovalAdvanceService.enqueuePendingAdvances(dispositions, priorById);
    }
}
