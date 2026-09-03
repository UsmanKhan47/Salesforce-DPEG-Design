/**
 * STAGE-ADVANCEMENT GATE ON `Transaction__c` — refuses to let a deal move FORWARD out of a stage
 * while any checklist item belonging to that stage is still open, and names what is outstanding.
 * Design `agent-output/design-checklist-cutover-and-stage-gate.md` Part B.
 *
 * layer=service. Zero inline SOQL — the single read is
 * `ChecklistItemSelector.selectOpenForStageGate`. Zero DML, always, in every path: this runs in a
 * BEFORE context and refuses through `SObject.addError` on records the platform is already saving.
 * No Domain class holds this rule because it needs a database read, which the Domain Purity Rule
 * forbids; the part that does NOT need one (the stage ORDER, and what "forward" means) does live
 * in `TransactionStageDomain`.
 *
 * =============================================================================================
 * WHY APEX AND NOT A VALIDATION RULE. SETTLED AT DESIGN B1 — DO NOT RE-LITIGATE IT.
 * =============================================================================================
 * The user's requirement is a HARD BLOCK "with a message naming what is outstanding". A
 * validation rule's `errorMessage` is a STATIC STRING, not a formula, so it can say "complete all
 * items in this stage first" and can never say WHICH items. That is half the requirement, and no
 * amount of roll-up-summary plumbing changes it. Three further reasons are recorded in the design:
 * a roll-up keyed on `Checklist__c.Stage__c` falls into NO bucket for a NULL stage and so fails
 * OPEN silently; it would add five fields (one of them a roll-up summary, which cannot take
 * `editable=true` FLS) to a live master-detail hierarchy; and it would put a second, declarative
 * copy of numbers `ChecklistRollupService` already computes in Apex.
 *
 * =============================================================================================
 * IT IS TRIGGER-ONLY BY CONTRACT.
 * =============================================================================================
 * `addError` is honoured by the platform inside a trigger and NOWHERE ELSE. A non-trigger caller
 * would receive the returned decision map and refuse absolutely nothing, while every stage move
 * saved normally — a gate that looks installed and is not. `TransactionTriggerHandler.beforeUpdate`
 * is the sole production caller. The `Trigger.isExecuting` guard around `addError` exists so unit
 * tests can assert the DECISION directly without depending on undefined behaviour; every
 * DML-driven test still exercises the real refusal.
 *
 * =============================================================================================
 * THE FOUR USER DECISIONS THIS IMPLEMENTS. CONFIRMED, NOT INFERRED.
 * =============================================================================================
 *   1. ALL items in the stage being left must be complete — not only the CRITICAL ones.
 *   2. HARD BLOCK, with a message naming what is outstanding. No warning mode, no override.
 *   3. EVERY FORWARD stage move. Backward and lateral moves are NOT gated.
 *   4. NEW MODEL ONLY (`Checklist_Item__c`). The legacy `Task` model gets no copy of this gate.
 *
 * =============================================================================================
 * TWO DELIBERATE FAIL-OPENS. BOTH ARE COUNTED SO THEY ARE ASSERTABLE RATHER THAN SILENT.
 * =============================================================================================
 * (i) A DEAL WITH NO CHECKLIST IS NEVER BLOCKED. `Checklist_Fanned_Out__c != true` leaves Pass 1
 *     before any query. This is not a convenience: it covers every seed-script deal, every scratch
 *     rebuild, every pre-cutover deal, and — for as long as `TaskFanoutService` is deployed — every
 *     deal still on the Task model. Without it, the first deploy makes a large part of the org
 *     unmovable. Decision 4 above is the same statement from the other side: a deal on the Task
 *     model can be advanced with 82 open Tasks and that is ACCEPTED. Do not "improve" this by
 *     adding a Task-side branch — it would be deleted again at M5, and it would make this gate
 *     depend on `TaskSelector`, a shared contract used by PM, Disposition and Broker Protection.
 *     A fail-open is indistinguishable from a gate that never fires, so it needs a PAIRED negative
 *     control: the same fixture with the flag flipped must REFUSE. See tests N7a/N7b.
 * (ii) AN ITEM THAT CANNOT BE ATTRIBUTED TO A STAGE IS NOT GATED ON. `Checklist_Item__c.Stage__c`
 *     has no default, deliberately, and the parent `Checklist__c.Stage__c` is the fallback. When
 *     BOTH are blank the item belongs to no phase tab a user can open, so refusing on it would
 *     brick the deal with an instruction nobody can follow. It is counted in
 *     `lastRunUnattributedItemCount` instead — the same device as
 *     `ChecklistFanoutService.lastRunUnstagedItemCount` — and the cutover verification step
 *     (design A3 check 4) is what keeps that count at zero in production.
 *
 * =============================================================================================
 * NO STAGE-SIZE CONSTANT EXISTS ANYWHERE IN THIS CLASS, AND NONE MAY BE ADDED.
 * =============================================================================================
 * Group F (12 items) is CONDITIONAL on `Loan_Required__c`, so Due Diligence is 46 items on a loan
 * deal and 34 on a no-loan deal, and BOTH ARE CORRECT AND COMPLETE. The gate counts the rows it
 * actually read for the deal in front of it. Neither 11, 46, 10, 15 nor 82 appears in this source.
 * `TaskRollupService`'s header states the rule as "Do not turn 82 into a constant anywhere", and
 * `lwc/activeTransactionsList`'s header records the incident where a hardcoded denominator
 * reported on work that did not exist. `ChecklistMigrationAuditService` had to solve the same
 * problem for its CRITICAL count and reached the same answer.
 *
 * =============================================================================================
 * THE MESSAGE IS PURE PRINTABLE ASCII. `addError` HTML-ESCAPES.
 * =============================================================================================
 * An em-dash renders as `&mdash;` in the toast AND breaks any `contains` match written against
 * the constant — a Phase 0 lesson that cost a test, recorded in
 * `ChecklistItemPrerequisiteService`. Every constant below is plain ASCII, and an interpolated
 * item Subject is NEVER wrapped in quotes because quotes render as `&quot;`. The item subjects
 * this org ships carry no ampersand, angle bracket or quote; that is a property of the data, not
 * a guarantee, which is why the purity assertion belongs in a test over a COMPOSED message.
 *
 * =============================================================================================
 * WHERE THE MESSAGE ENDS UP, AND WHY THAT IS VERIFIED RATHER THAN ASSUMED.
 * =============================================================================================
 * There are at least six writers of `Transaction__c.Stage__c`: the four `Move_to_*` quick actions,
 * the standard Path component, inline edit, the API, Data Loader and the seed scripts. ALL of them
 * go through `before update`, which is why the gate lives on the record and not on any action.
 * On the quick-action route the refusal survives intact: `RecordStageAdvanceService.setStage`
 * catches `DmlException` and rethrows `RecordStageAdvanceException(e.getDmlMessage(0))` under a
 * `getNumDml() > 0` guard, and its own comment says surfacing the platform message verbatim is the
 * POINT of routing those writes through Apex. So write the text for a human reading it in a toast.
 *
 * =============================================================================================
 * NO AUTOMATION IS BLOCKED BY THIS GATE, AND ONE BUSINESS CONSEQUENCE IS REAL.
 * =============================================================================================
 * `Transaction_Stage_Closed_Sets_Status` is a BEFORE-SAVE flow that READS `Stage__c` and writes
 * `Status__c`; before-save flows run BEFORE Apex before-triggers, so on a refusal its in-memory
 * assignment is discarded with the whole save and `Status__c` cannot drift.
 * `Transaction_Complete_Close` is AFTER-save, so a refusal means it never runs and the Opportunity
 * is not half-closed. The rollups, the fan-out's claim write and `DealTransactionGateService`
 * never move `Stage__c` at all, so they leave Pass 1 having spent nothing. NOTHING automated moves
 * a deal to `Closed` — that hop is the `Move_to_Closed_Won` quick action, i.e. a person.
 * THE CONSEQUENCE, STATED RATHER THAN BURIED: a deal can no longer be closed until every
 * Post-Closing (group J) item is complete, including J4 "Set up auto loan payment at lender bank"
 * (CRITICAL). That follows directly from user decision 3 and is correct; the surprise arrives
 * weeks after deploy, on the day somebody tries to close a deal, so the business is to be told
 * before go-live (design OQ-A).
 *
 * =============================================================================================
 * GOVERNOR BUDGET — DERIVED, NOT COPIED. Per BEFORE-UPDATE chunk (at most 200 records):
 * =============================================================================================
 *   SOQL, no forward stage move on a claimed deal in the chunk : 0. Pass 1 exits before any query.
 *       This covers EVERY rollup write, every fan-out claim write, every counter, flag and owner
 *       change — and it is what keeps `TransactionTriggerHandler`'s cost promise true.
 *   SOQL, at least one candidate : EXACTLY 1, for the whole chunk, however many deals are
 *       candidates and however many stages they are leaving. NEVER a function of row count.
 *   DML          : 0, always, in every path.
 *   Describes    : 0 at runtime. The stage order is a constant; describe is used only in the test
 *                  that cross-checks it.
 *   CMDT reads   : 0.
 *   Rows returned, worst case: 200 deals all leaving Due Diligence on loan deals is roughly 9,200
 *       rows of nine fields. That is well inside the 50,000-row SOQL limit but is an ESTIMATED
 *       1.5-2 MB against a 6 MB synchronous heap — inside it, not comfortably. The realistic shape
 *       is ONE deal (both the quick actions and the Path move a single record); a 200-row chunk of
 *       FORWARD STAGE MOVES only arises from Data Loader. If a bulk stage advance of many deals is
 *       ever needed, PAGE IT rather than widening this method.
 *   Cascade check: the Day-0 chain inserts the Transaction (before-INSERT, not gated) and the
 *       fan-out's final pass UPDATES it with counters and the claim flag WITHOUT moving `Stage__c`,
 *       so this gate adds nothing to that cascade.
 *
 * @see force-app/main/default/classes/TransactionTriggerHandler.cls (sole production caller)
 * @see force-app/main/default/classes/TransactionStageDomain.cls (the stage order)
 * @see force-app/main/default/classes/ChecklistItemSelector.cls (the single read)
 * @see force-app/main/default/classes/ChecklistItemDomain.cls (the single definition of done)
 * @see force-app/main/default/classes/ChecklistItemPrerequisiteService.cls (the shape mirrored)
 * @see agent-output/design-checklist-cutover-and-stage-gate.md B1-B7
 */
public with sharing class TransactionStageGateService {

    /**
     * How many outstanding items the message names before it summarises the rest.
     *
     * NOT A STAGE SIZE — it is a readability and message-length bound, and it is the same number
     * whatever stage is being left. At 46 Due Diligence items an uncapped message would be
     * unreadable in a toast and would approach the platform's error-message length limit. The
     * TOTAL count is always exact and always derived from the rows read; only the ENUMERATION is
     * capped, and the remainder is reported as "and N more".
     */
    @TestVisible
    private static final Integer MAX_ITEMS_NAMED = 5;

    /** Joins the enumerated items. Semicolon because item subjects contain commas and colons. */
    private static final String ITEM_SEPARATOR = '; ';

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // IN-CONTEXT GOVERNOR AND DECISION INSTRUMENTATION
    //
    // THESE EXIST BECAUSE THE OBVIOUS TEST IS SILENTLY VACUOUS. `Test.stopTest()` RESTORES the
    // pre-test governor counters, so `Limits.getQueries()` read after a bulk DML measures nothing
    // about what happened inside the trigger; and a reading taken before `stopTest` measures every
    // other service the trigger routes, not this one. The only falsifiable form of "zero SOQL
    // unless the chunk contains a forward stage move on a claimed deal, and exactly one otherwise"
    // is a delta measured ACROSS THIS METHOD'S OWN BODY, from inside the trigger context. Same
    // device as `ChecklistItemPrerequisiteService`, `TransactionStageEntryService` and
    // `ChecklistFanoutService.lastRunUnstagedItemCount`.
    //
    // CUMULATIVE ACROSS THE TRANSACTION until `resetRunCounters` is called, not per invocation —
    // a 251-record DML enters this method twice (200 + 51) and both firings must be summed for the
    // budget assertion to mean anything. In-transaction only; not a monitoring surface, never read
    // or reset by production code.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /** SOQL consumed by this class's own body. 0 when no candidate; 1 per chunk that has one. */
    @TestVisible
    private static Integer lastRunQueryCount = 0;

    /** DML consumed by this class's own body. Must be 0 at any record count, on every path. */
    @TestVisible
    private static Integer lastRunDmlCount = 0;

    /** Times the method was entered. A 251-record DML must produce at least 2 (200-row chunks). */
    @TestVisible
    private static Integer lastRunChunkCount = 0;

    /** Deals actually refused. A gate that never refuses is worthless; this makes it assertable. */
    @TestVisible
    private static Integer lastRunRefusalCount = 0;

    /**
     * Items whose stage could not be established from the item OR its parent checklist, and which
     * were therefore NOT gated on. Fail-open (ii) in the class header. Must be 0 in production.
     */
    @TestVisible
    private static Integer lastRunUnattributedItemCount = 0;

    /**
     * Stage moves where the prior or the new value is not one of the five recognised stages, and
     * which were therefore NOT gated. Catches a picklist value added in Setup without updating
     * `TransactionStageDomain`. Must be 0 in production.
     */
    @TestVisible
    private static Integer lastRunUnknownStageCount = 0;

    /** Zeroes the instrumentation. Test-only; production never calls it. */
    @TestVisible
    private static void resetRunCounters() {
        lastRunQueryCount = 0;
        lastRunDmlCount = 0;
        lastRunChunkCount = 0;
        lastRunRefusalCount = 0;
        lastRunUnattributedItemCount = 0;
        lastRunUnknownStageCount = 0;
    }

    /**
     * Refuses every FORWARD stage move in this chunk whose deal still has open checklist items in
     * the stage it is LEAVING. Called from `TransactionTriggerHandler.beforeUpdate` only.
     *
     * THE STAGE WHOSE ITEMS ARE JUDGED IS THE ONE BEING LEFT, NOT THE ONE BEING ENTERED. Moving to
     * Due Diligence requires the OPEN CONTRACT items to be complete. That is also what makes the
     * Post-Closing to `Closed` hop work at all: `Closed` is terminal and owns no checklist group,
     * so a gate keyed on the destination would have nothing to judge on the single most
     * consequential hop in the lifecycle.
     *
     * ORDER WITHIN THE BEFORE-UPDATE CONTEXT IS IMMATERIAL TO CORRECTNESS, AND THIS IS RECORDED SO
     * NOBODY "FIXES" IT. `TransactionStageEntryService.stampStageEntryDates` runs first and may
     * assign `Stage_Entry_Date__c` in memory on a record this method then refuses. On a refusal the
     * ENTIRE save is discarded, so that assignment never reaches the database. Reordering the two
     * arms changes nothing except which of them is listed first in the handler.
     *
     * @param newDeals Trigger.new (`Transaction__c`). Null/empty-safe.
     * @param oldMap   Trigger.oldMap. LOAD-BEARING: it supplies the stage being LEFT, which is the
     *                 stage whose items are judged. A null map (an insert, or a non-trigger caller)
     *                 makes every record leave through the first `continue`, so the gate refuses
     *                 nothing — which is correct for insert (design N9: a new deal has no checklist
     *                 by definition and gating insert would brick every seed script) and is one
     *                 more reason this method is trigger-only by contract.
     * @return Refusal messages by `Transaction__c` Id — empty when nothing was refused, never null.
     *         The handler ignores it; it exists so a unit test can assert the DECISION without
     *         depending on `addError`, which is only meaningful inside a trigger.
     * @example
     * Map&lt;Id, String&gt; refusals = TransactionStageGateService.enforceOnUpdate(newList, oldMap);
     */
    public static Map<Id, String> enforceOnUpdate(
        List<Transaction__c> newDeals,
        Map<Id, Transaction__c> oldMap
    ) {
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        try {
            return enforceChunk(newDeals, oldMap);
        } finally {
            // In a finally so an unexpected throw cannot leave the counters reading zero and make
            // a budget assertion pass for the wrong reason.
            lastRunChunkCount++;
            lastRunQueryCount += Limits.getQueries() - queriesBefore;
            lastRunDmlCount += Limits.getDmlStatements() - dmlBefore;
        }
    }

    /**
     * The gate itself, in three passes. Separated from the public method purely so the
     * instrumentation above can wrap the whole body including every early return.
     *
     * @param newDeals Trigger.new.
     * @param oldMap   Trigger.oldMap.
     * @return Refusal messages by deal Id.
     */
    private static Map<Id, String> enforceChunk(
        List<Transaction__c> newDeals,
        Map<Id, Transaction__c> oldMap
    ) {
        Map<Id, String> refusals = new Map<Id, String>();
        if (newDeals == null || newDeals.isEmpty()) {
            return refusals;
        }

        // ── PASS 1 — PURE MEMORY. NO QUERY IS REACHABLE FROM HERE. ─────────────────────────
        // Four tests, cheapest and most common first, so the overwhelming majority of saves on
        // this object leave having spent nothing at all. This ordering IS the zero-cost promise
        // in `TransactionTriggerHandler`'s header; do not reorder it.
        Map<Id, Transaction__c> candidateByDealId = new Map<Id, Transaction__c>();
        Map<Id, String> priorStageByDealId = new Map<Id, String>();
        Map<Id, String> nextStageByDealId = new Map<Id, String>();
        Set<String> stagesBeingLeft = new Set<String>();

        for (Transaction__c deal : newDeals) {
            Transaction__c prior = (oldMap == null || deal.Id == null) ? null : oldMap.get(deal.Id);
            if (prior == null) {
                // Not an update we can judge: no stored prior state to compare against.
                continue;
            }
            String priorStage = prior.Stage__c;
            String nextStage = deal.Stage__c;
            // Apex String equality is null-safe, so a deal with no stage on either side lands
            // here. THIS LINE IS THE ONE THAT MAKES EVERY COUNTER, FLAG, DATE AND OWNER WRITE ON
            // THIS OBJECT FREE — including every rollup write in the Day-0 cascade.
            if (priorStage == nextStage) {
                continue;
            }
            if (!TransactionStageDomain.isForward(priorStage, nextStage)) {
                // Backward and lateral moves are NOT gated (user decision 3). An UNRECOGNISED
                // value on either side is also not gated, and unlike a backward move that is a
                // fail-open worth seeing, so it is counted rather than merged into the same
                // silence. See the fail-open note in `TransactionStageDomain`'s header.
                if (!TransactionStageDomain.isKnown(priorStage)
                        || !TransactionStageDomain.isKnown(nextStage)) {
                    lastRunUnknownStageCount++;
                }
                continue;
            }
            if (deal.Checklist_Fanned_Out__c != true) {
                // Fail-open (i). Deliberate, and the reason is in the class header. `!= true`
                // rather than `== false` so a null (a caller that built the sObject by hand
                // without the field) is treated as unclaimed rather than throwing.
                continue;
            }
            candidateByDealId.put(deal.Id, deal);
            priorStageByDealId.put(deal.Id, priorStage);
            nextStageByDealId.put(deal.Id, nextStage);
            stagesBeingLeft.add(priorStage);
        }

        if (candidateByDealId.isEmpty()) {
            // ZERO SOQL, ZERO DML. The common case by a very wide margin.
            return refusals;
        }

        // ── PASS 2 — EXACTLY ONE QUERY, FOR THE WHOLE CHUNK. ───────────────────────────────
        // A defensive copy of the key set: `Map.keySet()` returns a live, read-only view, and
        // handing it to another class invites a `FinalException` the day that class decides to
        // add to it. The copy is a handful of ids.
        List<Checklist_Item__c> items = ChecklistItemSelector.selectOpenForStageGate(
            new Set<Id>(candidateByDealId.keySet()),
            stagesBeingLeft
        );

        // ── PASS 3 — IN MEMORY. ATTRIBUTE, TALLY, REFUSE. ──────────────────────────────────
        // `stageTotal` is the DENOMINATOR and it is counted from the rows in hand, per deal. It is
        // never a constant and never derived from a definition count — see the no-stage-size-
        // constant block in the class header.
        Map<Id, Integer> stageTotalByDealId = new Map<Id, Integer>();
        Map<Id, Integer> outstandingCountByDealId = new Map<Id, Integer>();
        Map<Id, List<String>> namedItemsByDealId = new Map<Id, List<String>>();

        for (Checklist_Item__c item : items) {
            // Master-detail, so this is populated for every row the query returned.
            Id dealId = item.Checklist__r == null ? null : item.Checklist__r.Transaction__c;
            if (dealId == null) {
                continue;
            }
            String priorStage = priorStageByDealId.get(dealId);
            if (priorStage == null) {
                // The query is scoped to the candidate deals, so this cannot normally happen. It
                // is a guard, not a branch with a behaviour.
                continue;
            }
            // The item's own stamp wins; the parent checklist is the fallback. Both blank means
            // the item belongs to no phase tab a user can open — fail-open (ii).
            String effectiveStage = String.isNotBlank(item.Stage__c)
                ? item.Stage__c
                : (item.Checklist__r == null ? null : item.Checklist__r.Stage__c);
            if (String.isBlank(effectiveStage)) {
                lastRunUnattributedItemCount++;
                continue;
            }
            if (effectiveStage != priorStage) {
                // An unstamped item the query returned by the `OR Stage__c = NULL` disjunct whose
                // parent belongs to a DIFFERENT stage. Correctly not this move's problem.
                continue;
            }

            Integer runningTotal = stageTotalByDealId.get(dealId);
            stageTotalByDealId.put(dealId, runningTotal == null ? 1 : runningTotal + 1);

            // THE SINGLE DEFINITION OF DONE, IN MEMORY. `Flag__c` is a lossy picklist in which
            // `Verified` is ALSO a done state, so a `Flag__c == 'Completed'` test anywhere would
            // silently count every verified wire item as open. Read `ChecklistItemDomain`'s header.
            if (ChecklistItemDomain.isDone(item.Flag__c)) {
                continue;
            }

            Integer runningOpen = outstandingCountByDealId.get(dealId);
            outstandingCountByDealId.put(dealId, runningOpen == null ? 1 : runningOpen + 1);

            List<String> named = namedItemsByDealId.get(dealId);
            if (named == null) {
                named = new List<String>();
                namedItemsByDealId.put(dealId, named);
            }
            // Bounded so the composed message does not grow with the row count, and so heap does
            // not either. The query is ordered by group then sequence, so the names kept are the
            // FIRST outstanding items in checklist order, which is where a user starts.
            if (named.size() < MAX_ITEMS_NAMED) {
                named.add(describeItem(item));
            }
        }

        // Iterating `newDeals` rather than a map keeps the refusal order deterministic and gives
        // access to the sObject `addError` must be called on.
        for (Transaction__c deal : newDeals) {
            if (deal.Id == null || !candidateByDealId.containsKey(deal.Id)) {
                continue;
            }
            Integer outstanding = outstandingCountByDealId.get(deal.Id);
            if (outstanding == null || outstanding == 0) {
                continue;
            }
            Integer stageTotal = stageTotalByDealId.get(deal.Id);
            String message = composeRefusal(
                nextStageByDealId.get(deal.Id),
                priorStageByDealId.get(deal.Id),
                outstanding,
                stageTotal == null ? outstanding : stageTotal,
                namedItemsByDealId.get(deal.Id)
            );
            refusals.put(deal.Id, message);
            lastRunRefusalCount++;

            // `addError` is documented as valid in trigger context only. Guarded so the direct
            // unit tests (which have no trigger to run inside) assert the returned map instead of
            // depending on undefined behaviour. Every DML-driven test exercises this line for real.
            //
            // PER-RECORD, NOT A CHUNK ABORT. Under `Database.update(deals, false)` the refused
            // deals fail and every other deal in the same statement still saves — which is the
            // behaviour a Data Loader operator needs, and which test N15 pins.
            if (Trigger.isExecuting) {
                deal.addError(message);
            }
        }
        return refusals;
    }

    /**
     * One outstanding item, rendered for a human: its coordinate then its subject.
     *
     * NEVER SUBJECT TEXT AS A KEY. The coordinate (`A4`, `B2`) is the identity; the subject is
     * display only and no branch anywhere reads it. The whole Phase 2/3 rewrite exists to retire
     * one subject-substring parse, and re-introducing one here would recreate that risk in a new
     * file where an admin retitling an item silently changes behaviour.
     *
     * The subject is NOT wrapped in quotes: `addError` HTML-escapes, so quotes would reach the
     * user as `&quot;`.
     *
     * @param item A returned `Checklist_Item__c` with its parent group letter traversed.
     * @return e.g. `A4 Receive critical dates from title company`. Degrades rather than throws
     *         when the coordinate or the subject is missing — a message is not the place to
     *         discover a data problem, and the COUNT is already exact without either.
     */
    private static String describeItem(Checklist_Item__c item) {
        String coordinate = TransactionStageDomain.coordinateOf(
            item.Checklist__r == null ? null : item.Checklist__r.Group_Letter__c,
            item.Sequence__c
        );
        String subject = String.isBlank(item.Subject__c)
            ? 'checklist item'
            : item.Subject__c;
        return coordinate == null ? subject : coordinate + ' ' + subject;
    }

    /**
     * The refusal a user reads in a toast.
     *
     * PURE PRINTABLE ASCII. No em-dash, no smart quote, no angle bracket, no ampersand, no double
     * quote — `addError` HTML-escapes its message, so any of those reaches the user mangled and
     * also breaks any `contains` assertion written against it.
     *
     * It names, in this order: where the deal was trying to go, how many of how many items in the
     * stage it is LEAVING are still open, which ones (up to `MAX_ITEMS_NAMED`, with the remainder
     * summarised), and where to go to fix it. Every number is derived from rows read for THIS deal.
     *
     * @param targetStage  The stage the save was moving TO. Named so the user knows which click
     *                     was refused when several are available.
     * @param leavingStage The stage being LEFT, whose items are judged.
     * @param outstanding  How many items in that stage are open. Exact, never capped.
     * @param stageTotal   How many items in that stage exist ON THIS DEAL. Counted, never
     *                     constant, and therefore correct for a no-loan deal with no group F.
     * @param named        Up to `MAX_ITEMS_NAMED` rendered items, in checklist order; may be null.
     * @return The user-facing refusal.
     */
    private static String composeRefusal(
        String targetStage,
        String leavingStage,
        Integer outstanding,
        Integer stageTotal,
        List<String> named
    ) {
        String verb = outstanding == 1 ? ' is still open' : ' are still open';
        String message = 'This deal cannot move to ' + targetStage + ' yet. '
            + String.valueOf(outstanding) + ' of ' + String.valueOf(stageTotal) + ' '
            + leavingStage + ' checklist items' + verb;

        if (named != null && !named.isEmpty()) {
            message += ': ' + String.join(named, ITEM_SEPARATOR);
            Integer notNamed = outstanding - named.size();
            if (notNamed > 0) {
                message += ITEM_SEPARATOR + 'and ' + String.valueOf(notNamed) + ' more';
            }
        }

        return message + '. Complete them on the ' + leavingStage + ' checklist first.';
    }
}
