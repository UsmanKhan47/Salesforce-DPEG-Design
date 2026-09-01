/**
 * Maintains the two child-count fields on `Disposition__c`:
 *
 *   `Offers_Received__c`     — every `Disposition_Offer__c` on the sale
 *   `Responses_Received__c`  — every `BOV_Submission__c` on the sale
 *
 * Added 2026-08-31 (Disposition BA gap closure, Tranche 1 item 7). Neither field can be a
 * roll-up summary: both children are joined by a LOOKUP, not a master-detail, so the platform's
 * roll-up is unavailable and this class is the substitute.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 IT RECOMPUTES. IT NEVER INCREMENTS. THIS IS THE WHOLE DESIGN.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * Every entry point reads the CURRENT count from an aggregate and writes that absolute number.
 * An incrementing counter cannot survive a reparent, a partial rollback, a data load, or a
 * Recycle-Bin restore, and — decisively — it can never self-heal: once wrong it stays wrong
 * forever, and nothing on any screen says so. Recomputing is idempotent, so the hand-seeded
 * values in the four disposition seed scripts CONVERGE on the truth on the next child save
 * rather than diverging from it.
 *
 * ⚠ THE COROLLARY IS THAT THIS IS A **RESET WRITER**, AND THAT CHANGES THE FAILURE DIRECTION.
 * A read that comes back short does not leave a stale value — it OVERWRITES a correct value with
 * a smaller one. That is why the two selector aggregates behind this class both escape sharing
 * (`DispositionOfferSelector.TractionReads`, `BovSubmissionSelector.CounterReads`) and why an
 * absent aggregate key must default to **0** rather than being skipped: deleting the last child
 * is exactly the case where `GROUP BY` emits no row, and skipping it would leave a sale reading
 * "3 offers" forever after all three were withdrawn.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * THE BUDGET, WHICH IS PART OF THE CONTRACT AND IS ASSERTED IN THE TESTS
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * PER TRIGGER CHUNK, per counted object: **ONE aggregate query and ONE `Database.update`.**
 * Never one per record, never one per disposition. `.claude/rules/bulk-test-rule.md` applies in
 * full here — these methods are trigger-driven and loop over collections, so no exemption is
 * available and none is claimed. `DispositionCounterRollupServiceTest` asserts the budget itself
 * at 251 rows, not merely that 251 rows produced 251 counters: a per-record write would produce
 * the right numbers and exhaust the 150-statement limit in production.
 *
 * 🔴 THE ZERO-QUERY FAST PATH IS NOT AN OPTIMISATION — IT IS WHAT KEEPS THE EXISTING SUITE GREEN
 * AND THE ORG'S ORDINARY SAVES FREE. Both trigger-shaped entry points are CHANGE-KEYED on the
 * `Disposition__c` lookup: an update in which no row moved parent returns after one in-memory
 * pass, before any SOQL and before any DML. That is the same shape
 * `BovSubmissionBrokerStampService` and `DispositionOfferBuyerStampService` already use, and it
 * is why `BovSubmissionTriggerHandlerTest.bulk251ApprovesAtConstantCost` (which asserts EXACTLY
 * 2 queries and 3 DML around a 251-row approval update) still passes with this class wired in.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * LAYERING — WHY THE DML IS HERE AND NOT IN THE TWO TRIGGER HANDLERS
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `.claude/rules/apex-layering-rule.md` gives the Service layer orchestration + DML and forbids
 * the Handler layer both. ⚠ `DispositionOfferTriggerHandler` and `BovSubmissionTriggerHandler`
 * each already hold a `ParentAdvanceWrites` inner class doing their own parent DML — that is
 * pre-existing and is NOT the precedent to copy. The counter's write lives here; the handlers
 * route and nothing else. Their headers cross-reference `ParentCounterWrites` below rather than
 * restating its argument, because a justification duplicated in three files is a justification
 * that will disagree with itself within a month.
 *
 * ZERO INLINE SOQL. Both counts come from selectors:
 *   `DispositionOfferSelector.selectOfferTractionByDispositionIds` (reused — see below)
 *   `BovSubmissionSelector.countByDispositionIds`                  (added with this class)
 *
 * ⚠ THE OFFER COUNT REUSES THE TRACTION AGGREGATE AND THAT IS DELIBERATE. The Tranche 1 design
 * instructed "reuse the EXISTING `DispositionOfferSelector.countByDispositionIds`". That method
 * was DELETED on 2026-08-21 and the design (and the listing-alerts design it inherited the line
 * from) had not caught up. `selectOfferTractionByDispositionIds` returns the same number, from
 * the same unfiltered aggregate, at the same one-query cost; resurrecting a count-only twin would
 * have added a second query against one table for one number, which that selector's header
 * explicitly forbids. The instruction's INTENT — do not add a second aggregate — is honoured.
 *
 * @see DispositionOfferSelector
 * @see BovSubmissionSelector
 * @see DispositionOfferTriggerHandler
 * @see BovSubmissionTriggerHandler
 */
public with sharing class DispositionCounterRollupService {

    /**
     * Every parent-write failure from the most recent recompute, as
     * `<dispositionId> -> <STATUS_CODE> | <message>`. Empty on a clean run and reset at the top of
     * every `applyCounts` call, so it describes ONE recompute and not a session.
     *
     * ⚠ IT EXISTS TO BE ASSERTED ON, not merely to be read — the same role
     * `DispositionOfferTriggerHandler.lastRunParentWriteFailures` plays, and for the same reason:
     * `allOrNone = false` means a refused counter write throws nothing at all, so without a
     * channel the failure is indistinguishable from success from every surface a person can see.
     * The non-owner test asserts this is EMPTY, which is what makes it fail loudly with the actual
     * `StatusCode` if `ParentCounterWrites` is ever un-escaped.
     */
    @TestVisible
    private static List<String> lastRunFailures = new List<String>();

    // ═════════════════════════════════════════════════════════════════════════════════════
    // OFFERS -> Disposition__c.Offers_Received__c
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * Recomputes `Offers_Received__c` for each supplied Disposition.
     *
     * COUNTS EVERY OFFER, WHATEVER ITS STATUS (design decision D-9). Story 37 keeps Rejected,
     * Countered and Withdrawn offers visible on the sale, so they are part of "offers received".
     * The selector carries no status predicate and must not gain one.
     *
     * @param dispositionIds Disposition__c Ids to recount; null/empty safe (returns at zero cost).
     * @example
     * DispositionCounterRollupService.recalculateOffersFor(new Set<Id>{ dispId });
     */
    public static void recalculateOffersFor(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return;
        }
        // 🔴 ONE selector call for the whole set, hoisted ABOVE the loop. The traction selector
        // returns a wrapper, so a `countById` map has to be built from it — and the obvious way to
        // build it (call the selector inside the loop, keyed on one Id) is SOQL-in-a-loop wearing a
        // selector's clothes. The call is here, once; the loop only unwraps.
        Map<Id, DispositionOfferSelector.OfferTraction> tractionById =
            DispositionOfferSelector.selectOfferTractionByDispositionIds(dispositionIds);
        Map<Id, Integer> countById = new Map<Id, Integer>();
        for (Id dispositionId : tractionById.keySet()) {
            countById.put(dispositionId, tractionById.get(dispositionId).offerCount);
        }
        applyCounts(dispositionIds, countById, Disposition__c.Offers_Received__c);
    }

    /**
     * Trigger-shaped entry point for `Disposition_Offer__c`. Works out which parents can have
     * changed, then delegates.
     *
     * @param offers    `Trigger.new` on insert / update / undelete, `Trigger.old` on delete.
     * @param priorById `Trigger.oldMap` on update; **null** in every other context.
     */
    public static void recalculateOffersForRows(
        List<Disposition_Offer__c> offers,
        Map<Id, Disposition_Offer__c> priorById
    ) {
        if (offers == null) {
            return;
        }
        Set<Id> affected = new Set<Id>();
        for (Disposition_Offer__c offer : offers) {
            Disposition_Offer__c prior = (priorById == null) ? null : priorById.get(offer.Id);
            addAffected(affected, offer.Disposition__c, prior == null ? null : prior.Disposition__c,
                priorById != null);
        }
        recalculateOffersFor(affected);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // BOV SUBMISSIONS -> Disposition__c.Responses_Received__c
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * Recomputes `Responses_Received__c` for each supplied Disposition.
     *
     * COUNTS EVERY SUBMISSION, WHATEVER ITS STATUS (design decision D-9) — a `Backup` response is
     * still a response, and `BovController.getOutreachSummary`'s "3 responses generates the
     * matrix" rule has always meant three brokers came back, not three of one kind.
     *
     * @param dispositionIds Disposition__c Ids to recount; null/empty safe (returns at zero cost).
     * @example
     * DispositionCounterRollupService.recalculateResponsesFor(new Set<Id>{ dispId });
     */
    public static void recalculateResponsesFor(Set<Id> dispositionIds) {
        if (dispositionIds == null || dispositionIds.isEmpty()) {
            return;
        }
        applyCounts(
            dispositionIds,
            BovSubmissionSelector.countByDispositionIds(dispositionIds),
            Disposition__c.Responses_Received__c
        );
    }

    /**
     * Trigger-shaped entry point for `BOV_Submission__c`. Works out which parents can have
     * changed, then delegates.
     *
     * @param submissions `Trigger.new` on insert / update / undelete, `Trigger.old` on delete.
     * @param priorById   `Trigger.oldMap` on update; **null** in every other context.
     */
    public static void recalculateResponsesForRows(
        List<BOV_Submission__c> submissions,
        Map<Id, BOV_Submission__c> priorById
    ) {
        if (submissions == null) {
            return;
        }
        Set<Id> affected = new Set<Id>();
        for (BOV_Submission__c submission : submissions) {
            BOV_Submission__c prior =
                (priorById == null) ? null : priorById.get(submission.Id);
            addAffected(affected, submission.Disposition__c,
                prior == null ? null : prior.Disposition__c, priorById != null);
        }
        recalculateResponsesFor(affected);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // SHARED MECHANICS
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * Decides which parent Ids a single child row puts in play.
     *
     * ── 🔴 THE UPDATE BRANCH IS THE ONE THAT IS EASY TO GET WRONG ─────────────────────────────
     * On an UPDATE, a row only affects a counter if it MOVED PARENT — and then it affects
     * **TWO**: the one it left (now one too high) and the one it joined (now one too low). A
     * handler that recomputes only `Trigger.new`'s parent leaves the old sale permanently
     * over-counted, with nothing to notice it, which is the defect this method exists to prevent.
     *
     * ── AND THE ZERO-QUERY FAST PATH FALLS OUT OF THE SAME TEST ───────────────────────────────
     * When the lookup did NOT move, nothing is added. A chunk of 251 status changes, score edits
     * or approval stamps therefore leaves `affected` empty and the caller returns before any SOQL.
     * `isUpdate` is passed explicitly rather than inferred from `prior != null`, because
     * `Trigger.oldMap` can legitimately miss a key and inferring would silently reclassify such a
     * row as an INSERT — i.e. as always-affected — quietly deleting the fast path.
     *
     * @param affected     Accumulator, mutated in place.
     * @param currentValue The row's `Disposition__c` now; may be null (the lookup is optional).
     * @param priorValue   The row's `Disposition__c` before this save; null outside an update.
     * @param isUpdate     True only in the after-update context.
     */
    private static void addAffected(
        Set<Id> affected,
        Id currentValue,
        Id priorValue,
        Boolean isUpdate
    ) {
        if (!isUpdate) {
            if (currentValue != null) {
                affected.add(currentValue);
            }
            return;
        }
        if (currentValue == priorValue) {
            return; // 🔴 THE FAST PATH. No reparent, no recount, no query, no DML.
        }
        if (currentValue != null) {
            affected.add(currentValue);
        }
        if (priorValue != null) {
            affected.add(priorValue);
        }
    }

    /**
     * Builds one update shell per parent and applies them in ONE statement.
     *
     * 🔴 IT ITERATES `dispositionIds`, NOT `countById.keySet()`, AND THAT IS THE DECREMENT. A
     * `GROUP BY` emits no row for an empty group, so a sale whose last child was just deleted is
     * ABSENT from `countById` — iterating the map would skip precisely the row that needs writing
     * and the counter would only ever be able to go up. `BLANKVALUE`-style defaulting to 0 here is
     * the entire decrement path.
     *
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * ⚠ THE SHELL CARRIES `Id` AND THE COUNTER AND NOTHING ELSE. That is what keeps the cascade
     * free — AND THE AUDIT BEHIND THAT CLAIM COVERS ALL **FOUR** `DispositionTrigger` CONSUMERS,
     * NOT JUST THE TWO AFTER-CONTEXT ONES.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 CORRECTED 2026-08-31 (Tranche 1 code review, W-1). Retracted in place rather than edited,
     * because a reader who carries the old sentence away will audit the wrong half of the trigger:
     *
     *     RETRACTED, LAST SENTENCE ONLY: "Measured against those two methods' change keys, not
     *     assumed."
     *
     * WHAT WAS RIGHT AND STAYS RIGHT: every word about the two after-context consumers, and the
     * conclusion — the shell really is free. The numbers derived from it did not move.
     * WHAT WAS WRONG: "those two" described `DispositionTriggerHandler.afterUpdate` alone, while
     * `DispositionTrigger` declares `(before insert, before update, after insert, after update)`
     * and the handler routes TWO MORE consumers in the before contexts. A shell `Database.update`
     * fires the before contexts as well, so an audit that stops at two is an audit of half the
     * cascade. The next person adding a before-context consumer would have read "two", found two,
     * and skipped the check that matters.
     *
     * ALL FOUR CONSUMERS, AND WHY EACH IS FREE FOR THIS SHELL (derived from each method's change
     * key on 2026-08-31; DERIVED, NOT MEASURED — nothing here has been run):
     *   1. `DispositionStageEntryService.stampListingDates` (before insert + before update) —
     *      returns on the first `if` for any row not at `Active Listing`, and for a row that IS
     *      there, `Trigger.new` in a before-UPDATE context carries the full committed record, so
     *      prior stage == current stage and it `continue`s. Zero SOQL and zero DML on every path
     *      it has: the whole method is an in-memory pass.
     *   2. `DispositionBrokerStampService.stampSelectedBrokerLabel` (before insert + before
     *      update) — change-keyed on `Broker__c`; the shell does not carry it, so `changed` is
     *      empty and the method returns BEFORE its one Contact query.
     *   3. `DispositionStageEntryService.createStageEntryRecords` (after insert + after update,
     *      via `DispositionTriggerHandler.route`) — keyed on `Disposition_Stage__c` CHANGING; in
     *      an after-update context old and new stage are identical, so it `continue`s at zero
     *      cost.
     *   4. `DispositionApprovalAdvanceService.enqueuePendingAdvances` (after insert + after
     *      update, same `route`) — keyed on `Approval_Advance_Pending__c` TRANSITIONING to true;
     *      likewise untouched by the shell.
     *
     * 🔴 Adding any other field to this shell re-opens that question — against all four, and
     * against any fifth that joins either context. `DispositionTriggerHandler` is the inventory;
     * this list is a snapshot of it and will go stale the same way the sentence above did.
     *
     * @param dispositionIds Every parent in play — the authoritative set.
     * @param countById      Aggregate result; a MISSING key means zero, not "leave alone".
     * @param counterField   `Offers_Received__c` or `Responses_Received__c`.
     */
    private static void applyCounts(
        Set<Id> dispositionIds,
        Map<Id, Integer> countById,
        Schema.SObjectField counterField
    ) {
        List<Disposition__c> parents = new List<Disposition__c>();
        for (Id dispositionId : dispositionIds) {
            Integer counted = countById.get(dispositionId);
            Disposition__c parent = new Disposition__c(Id = dispositionId);
            parent.put(counterField, (counted == null) ? 0 : counted);
            parents.add(parent);
        }
        if (parents.isEmpty()) {
            return;
        }
        recordFailures(new ParentCounterWrites().apply(parents), parents, counterField);
    }

    /**
     * Sends every refused row to `lastRunFailures` and to the debug log at ERROR.
     *
     * ⚠ NOTHING IS RETHROWN AND NOTHING IS RETRIED. Both would roll back the user's own child
     * save — see the `allOrNone = false` argument at `ParentCounterWrites` — and this method must
     * be incapable of doing that. It is a report, not a recovery. Shape copied from
     * `DispositionOfferTriggerHandler.recordParentWriteFailures`, which learned it the hard way.
     *
     * ⚠ TWO REFUSALS ARE EXPECTED RATHER THAN EXCEPTIONAL AND ARE STILL LOGGED ON PURPOSE:
     *   1. `ENTITY_IS_DELETED` — deleting a Disposition SetNulls its children's lookups, so the
     *      cascade can put an Id in play whose parent is going away in the same transaction.
     *   2. `FIELD_CUSTOM_VALIDATION_EXCEPTION` from `Broker_Lookup_Is_Off_Market_Only`, which is
     *      the ONE Disposition validation rule not guarded by `ISCHANGED` — it re-evaluates on
     *      every save, so a legacy row that already violates it refuses this write too.
     * Both are visible, bounded and hand-recoverable. Suppressing either would also suppress the
     * sharing failure this channel exists to surface, so neither is filtered out.
     *
     * @param results      Parallel to `attempted`, in input order; never null.
     * @param attempted    The shells handed to the DML, used only for their Ids.
     * @param counterField Named in the log line so a failure says WHICH counter went stale.
     */
    private static void recordFailures(
        List<Database.SaveResult> results,
        List<Disposition__c> attempted,
        Schema.SObjectField counterField
    ) {
        lastRunFailures = new List<String>();
        // `getDescribe().getName()` rather than `String.valueOf(counterField)` — the latter also
        // yields the API name today, but it is a toString() contract, not a documented accessor,
        // and this string ends up in the ONE log line a stale counter produces.
        String fieldName = counterField.getDescribe().getName();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                continue;
            }
            List<Database.Error> errors = results[i].getErrors();
            String detail = errors.isEmpty()
                ? 'no error detail returned'
                : errors[0].getStatusCode() + ' | ' + errors[0].getMessage();
            lastRunFailures.add(attempted[i].Id + ' -> ' + detail);
            // NOT debug output — this is the failure channel; see lastRunFailures. With
            // `allOrNone = false` a refused counter write throws nothing, so removing this line
            // restores the silent no-op this method exists to close. A lint pass will flag it;
            // leave it.
            System.debug(LoggingLevel.ERROR,
                'DispositionCounterRollupService: STALE COUNTER on Disposition__c '
                + attempted[i].Id + '.' + fieldName + ' -> ' + detail
                + ' | the child rows changed and the parent counter did NOT follow. '
                + 'Running user: ' + UserInfo.getUserId() + '.');
        }
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE ONE STATEMENT THAT ESCAPES SHARING, AND WHY IT HAS TO (design decision D-10).
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * WHO RUNS THIS CODE: whoever saved a `Disposition_Offer__c` or a `BOV_Submission__c`. That is
     * routinely NOT the owner of the parent `Disposition__c` — a broker submits a BOV, an analyst
     * logs a competing offer, an approver's field update cascades — and `Disposition__c` is OWD
     * **Private** (`sharingModel = Private`, in the object file).
     *
     * 🔴 `AccessLevel.SYSTEM_MODE` IS NOT SUFFICIENT AND COULD NEVER BE. Per ARCHITECTURE.md §2:
     * *"`SYSTEM_MODE` bypasses CRUD/FLS ONLY — it does NOT bypass sharing."* Both disposition
     * permission sets carry `viewAllRecords = true` on `Disposition__c` and NO `modifyAllRecords`
     * — which is exactly the trap: the saver can READ every sale and EDIT almost none, so the
     * counter write is refused at the RECORD level after SYSTEM_MODE has already cleared the
     * object level. This repo has a measured production incident of precisely that shape
     * (`DispositionOfferTriggerHandler.ParentAdvanceWrites`, 2026-08-21): the write got far enough
     * to produce a `SaveResult`, `allOrNone = false` swallowed it, and nobody read it.
     * ⚠ A COUNTER THAT DIVERGES FOR NON-OWNERS IS WORSE THAN AN ABSENT ONE. It renders as a
     * confident number beside the related list that contradicts it, and it drives
     * `BovController.getOutreachSummary`'s `>= 3` matrix threshold.
     *
     * THREE SEPARATE DECISIONS ON ONE STATEMENT. NONE COVERS ANOTHER'S OBSTACLE:
     *   SYSTEM_MODE      lifts CRUD + FLS. Both counter fields are read-only FLS in BOTH
     *                    disposition permission sets by design (they are machine-maintained), so
     *                    a `USER_MODE` write would be refused for every human in the org.
     *   without sharing  lifts RECORD-LEVEL access — this class. The decision above does not.
     *   allOrNone=false  keeps a refusal from rolling back THE USER'S OWN CHILD SAVE. A counter
     *                    must never be able to destroy the transaction it counts.
     *
     * WHY THE ESCAPE IS BOUNDED TO THIS ONE WRITE: the outer class stays `with sharing`, both
     * selectors stay `with sharing`, and this inner class holds ONE statement against a list the
     * CALLER built. It cannot query, cannot choose rows, and cannot widen — every Id in `parents`
     * came off a child row's own `Disposition__c` lookup in the running trigger context, so it
     * names a sale the saver was already writing a child against. ARCHITECTURE.md §2 prescribes
     * exactly this shape: *"a narrow `private without sharing` inner class holding only that
     * query… never `without sharing` on a whole selector"*.
     *
     * ⚠ DO NOT PROMOTE THIS TO THE OUTER CLASS. Everything else here is deliberately
     * sharing-scoped, and `without sharing` on the service would silently re-authorise any future
     * method added beside it.
     */
    private without sharing class ParentCounterWrites {
        /**
         * @param parents Disposition shells carrying Id + exactly one counter field; never empty.
         * @return One `Database.SaveResult` per row, in input order. The caller inspects them.
         */
        private List<Database.SaveResult> apply(List<Disposition__c> parents) {
            return Database.update(parents, false, AccessLevel.SYSTEM_MODE);
        }
    }
}
