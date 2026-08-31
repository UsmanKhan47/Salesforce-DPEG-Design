/**
 * WIRE-FRAUD PREREQUISITE GATE ON THE `Checklist_Item__c` MODEL — refuses to let a checklist item
 * be completed while the item it depends on is still open. Story 28; design
 * `agent-output/design-transaction-fsd-gaps.md` §5.1, Phase 2 (§10).
 *
 * layer=service. Zero inline SOQL — the single read is `ChecklistItemSelector.selectByIdsWithDeal`.
 * Zero DML — this runs in BEFORE contexts and mutates the records the platform is already saving.
 * No Domain class holds this rule: it needs a database read, which the Domain Purity Rule forbids.
 * The parts that do NOT need one (what "done" means, the completion stamp) DO live in
 * `ChecklistItemDomain`, which is the difference from Phase 0, where nothing was extractable.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE PHASE 0 BYPASS FAMILY — WHAT THE NEW MODEL KILLS, AND WHAT IT DOES NOT.
 *    READ THIS BEFORE CHANGING ANY BRANCH BELOW. TWO OF THE FOUR SHAPES ARE STILL REACHABLE.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * The equivalent gate on standard `Task` took three review rounds and four one-save bypasses to
 * close, because `Task` cannot be a lookup TARGET on this platform (`referenceTo` = `Task` fails
 * deploy), so the prerequisite had to be a `Text(20)` key (`B|2`) resolved against a SIBLING
 * matched on the triple (deal, group letter, sequence). Here `Blocked_By__c` is a REAL
 * `Lookup(Checklist_Item__c)` and the parent is a non-reparentable master-detail. Shape by shape:
 *
 * ── SHAPE 1 — BLANK THE KEY AND COMPLETE, IN ONE SAVE ────────────────── 🔴 STILL REACHABLE
 *      update new Checklist_Item__c(Id = b3Id, Flag__c = 'Completed', Blocked_By__c = null);
 *    A LOOKUP CAN BE NULLED EXACTLY LIKE A TEXT FIELD. Nothing about the relationship being real
 *    prevents this, and any brief claiming the whole family is "unreachable by construction" is
 *    wrong about this shape. It is CLOSED BY DEFENCE, not by schema: the surviving-key rule below
 *    (`survivingBlockedBy`) resolves the STORED value while the row is open, so the save cannot
 *    choose its own examiner, and branch (B) additionally refuses the blanking save itself.
 *
 * ── SHAPE 2 — REPOINT THE KEY AT SOMETHING ALREADY COMPLETE ──── 🔴 STILL REACHABLE, AND WIDER
 *      update new Checklist_Item__c(Id = b3Id, Flag__c = 'Completed', Blocked_By__c = someDoneId);
 *    ⚠ WIDER THAN ON `Task`, NOT NARROWER. The text key `A|1` could only ever name a sibling under
 *    the SAME deal — the query was scoped by `Transaction_Deal__c`. A lookup accepts ANY
 *    `Checklist_Item__c` Id in the org, including one under a DIFFERENT Transaction, and the
 *    platform enforces no scoping at all on a self-lookup. So the real relationship removes the
 *    parsing failure modes and simultaneously widens this one. CLOSED BY THREE THINGS TOGETHER:
 *    the surviving-key rule, branch (B)'s disarm refusal, and branch (D), which is NEW here and
 *    has no Phase 0 counterpart — a `Blocked_By__c` resolving outside this item's own Transaction
 *    is refused outright and never counts as met.
 *
 * ── SHAPE 3a — RE-PARENT THE DEPENDENT ONTO A DEAL WHOSE PREREQUISITE IS DONE ──── ✅ DEAD
 *    Phase 0's EXPLOIT A: `Blocked_By__c` was only HALF the coordinate, so moving
 *    `Transaction_Deal__c` re-scoped the resolution while the key half stayed correctly pinned.
 *    TWO INDEPENDENT REASONS IT CANNOT HAPPEN HERE, either of which alone would suffice:
 *      (i)  `Checklist_Item__c.Checklist__c` is MASTER-DETAIL with
 *           `reparentableMasterDetail=false`. The platform REFUSES the write — this is not a rule
 *           this class enforces, it is a DML error raised before any trigger sees the value.
 *      (ii) Even if it were reparentable, the parent DOES NOT PARTICIPATE IN RESOLUTION. The
 *           prerequisite is found by Id, not by (deal, letter, sequence). Re-scoping is
 *           meaningless against a pointer.
 *
 * ── SHAPE 3b — RENUMBER THE PREREQUISITE'S OWN IDENTITY FIELDS ──────────────────── ✅ DEAD
 *    Phase 0's residual 4b, which its own header judged UN-CLOSEABLE inside that budget (closing
 *    it needed a reverse lookup asked of every Task whose sequence, group or deal changed — a
 *    query on a context that has none, at Day-0 fan-out scale). Setting B2's `Sequence__c` to 99
 *    orphaned B3's `B|2` key, after which the key could be "repaired" away and B3 completed.
 *    DEAD BY CONSTRUCTION HERE: an Id does not change when the row it names is renumbered,
 *    re-lettered or re-labelled. NO identity field of the prerequisite is read by this class at
 *    all — only its `Flag__c` and its grandparent deal. There is nothing to renumber.
 *
 * ⚠ THE GENERALISABLE LESSON FROM PHASE 0, AND WHY THE ANSWERS SPLIT 2-2. Round 3 taught that
 * "a fix that hardens ONE coordinate of a multi-part key is incomplete by default — ask which
 * other part is still read from `Trigger.new`". On this model the answer is NONE: the multi-part
 * key is gone and there is exactly ONE coordinate. That is precisely why 3a and 3b die for free
 * and why 1 and 2 do not — 1 and 2 are attacks on the coordinate ITSELF, and no schema change can
 * remove those. They can only be defended, and they are, below.
 *
 * ── 🔴 ONE NEW RESIDUAL THE LOOKUP INTRODUCES, WHICH THE TEXT KEY DID NOT HAVE ──────────────
 * `Blocked_By__c` carries `deleteConstraint=SetNull`. DELETING THE PREREQUISITE ITEM SILENTLY
 * UNGATES THE DEPENDENT: the platform nulls the field, the dependent stops being a candidate, and
 * this class never sees it again. There is no trace and nothing here can detect it, because there
 * is nothing left to resolve. The `Text` key was strictly better in this ONE dimension — a key
 * naming a deleted row survived and failed CLOSED. Three things bound it, none of them code:
 *   • both rows are master-detail children of the same `Checklist__c`, so deleting the GROUP
 *     removes the dependent too and no orphaned-but-ungated row survives;
 *   • `ChecklistFanoutService.reconcile` refuses to remove a group any of whose items is done,
 *     which is the only production path that deletes checklists;
 *   • the real control is the PERMISSION PASS — `Checklist_Item__c` Delete must NOT be granted to
 *     the checklist personas. Treat any change to that grant as a change to this control's threat
 *     model, exactly as Phase 0 said of `Task_Sequence__c`'s FLS.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 NO SUBJECT-TEXT PARSING, AND NO GROUP-LETTER PARSING EITHER.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * Phase 0 keyed on `Group_Letter__c` + `Sequence__c` — structured, but still parsed, and the parse
 * capped the letter at ONE character, which meant a prerequisite pair could never be defined
 * inside group `H2` and such a pair would have failed CLOSED (uncompletable) rather than merely
 * un-gated. THAT LIMITATION IS GONE: nothing here parses anything. A pair in H2, or across groups,
 * or across phases, is just a lookup. The pairs themselves come from
 * `Transaction_Task_Def__mdt.Blocked_By_Sequence__c` / `.Blocked_By_Group_Letter__c` and are
 * stamped by `ChecklistFanoutService` — DATA, so a third pair is a definition edit and a loader
 * re-run, which is what design §5.1 asked for and Phase 0 could not deliver.
 * ⚠ The prerequisite's `Subject__c` IS interpolated into the refusal MESSAGE. That is DISPLAY, not
 * control flow — no branch here reads it. Do not "tidy" it into a match.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * GOVERNOR BUDGET (pinned by `ChecklistItemPrerequisiteServiceTest` against named counters)
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 *   SOQL per BEFORE-UPDATE chunk : 0 when no item in the chunk carries a `Blocked_By__c` on
 *                                  either side (the overwhelming case — 2 of ~82 items per deal);
 *                                  EXACTLY 1 otherwise. NEVER a function of row count.
 *   SOQL per BEFORE-INSERT chunk : 0, always. `clampOnInsert` performs no lookup, deliberately —
 *                                  see its Javadoc for the fan-out arithmetic.
 *   DML  per chunk               : 0, always, in BOTH contexts. In-memory mutation only.
 *   Rows returned                : candidates + their prerequisites, so at most 2x the number of
 *                                  gated rows in the chunk. Both are asked for in ONE query on
 *                                  purpose — the candidate rows are needed for their grandparent
 *                                  deal (branch D) and asking separately would double the SOQL.
 *   Permission gate              : +0 SOQL on every path this budget cares about, and AT MOST +1
 *                                  per TRANSACTION. `hasPrereqOverrideAccess` is asked ONLY from
 *                                  branch (B), after four cheap conditions have established that
 *                                  the save is a disarm attempt. The `&&` ordering is load-bearing
 *                                  — do not reorder the conjuncts.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ SHARING AND MODE
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * `with sharing`; the selector read is `WITH SYSTEM_MODE`, justified at its own declaration in
 * `ChecklistItemSelector`. SYSTEM_MODE lifts CRUD/FLS and NEVER sharing — and here that costs
 * nothing, which is another structural gain over Phase 0. `Checklist_Item__c` is
 * `ControlledByParent` all the way up to `Transaction__c`, and a detail record has no `OwnerId`,
 * so an item CANNOT be individually reassigned away from the deal team. The Phase 0 residual "a
 * REASSIGNED checklist Task can hide its prerequisite" has no counterpart here: either you can see
 * the whole deal or you can see none of it, and seeing none of it fails CLOSED (unresolved).
 *
 * @see force-app/main/default/classes/ChecklistItemTriggerHandler.cls (sole production caller)
 * @see force-app/main/default/classes/ChecklistItemSelector.cls (the single read)
 * @see objects/Checklist_Item__c/validationRules/Prerequisite_Must_Be_Met_To_Complete
 * @see agent-output/design-transaction-fsd-gaps.md §5.1, §10
 */
public with sharing class ChecklistItemPrerequisiteService {

    /**
     * ⚠ PURE ASCII, DELIBERATELY. `SObject.addError` HTML-ESCAPES ITS MESSAGE, so an em-dash in a
     * constant renders as `&mdash;` in the toast AND breaks any `contains` match written against
     * the constant — a Phase 0 lesson that cost a test. Keep every user-facing constant here to
     * plain ASCII, and never wrap an interpolated subject in quotes for the same reason.
     */
    @TestVisible
    private static final String MSG_BLOCKED =
        'This item cannot be completed yet. Complete the wire-fraud verification step first. Waiting on: ';

    /** Refusal when the surviving `Blocked_By__c` resolves to nothing at all. Fails CLOSED. */
    @TestVisible
    private static final String MSG_UNRESOLVED =
        'This item cannot be completed: its required prerequisite item could not be found. '
        + 'Ask an administrator to check the checklist prerequisite link.';

    /** Refusal when a save tries to blank or repoint the coordinate of a still-armed gate. */
    @TestVisible
    private static final String MSG_DISARM =
        'The prerequisite link on this item cannot be changed or removed while its wire-fraud '
        + 'verification step is still open.';

    /**
     * Refusal when a save points `Blocked_By__c` outside this item's own deal, or at the item
     * itself. NEW ON THIS MODEL — a lookup accepts any row in the org, which the Phase 0 text key
     * could not express. See SHAPE 2 in the class header.
     */
    @TestVisible
    private static final String MSG_CROSS_DEAL =
        'A checklist item can only be blocked by another item on the same deal, and never by '
        + 'itself.';

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // IN-CONTEXT GOVERNOR INSTRUMENTATION
    //
    // 🔴 THESE EXIST BECAUSE THE OBVIOUS TEST IS SILENTLY VACUOUS. `Test.stopTest()` RESTORES the
    // pre-test governor counters, so `Limits.getQueries()` read after a bulk DML measures nothing
    // about what happened inside the trigger. The only falsifiable form of "exactly one query per
    // chunk, never a function of row count" is a delta measured ACROSS THIS METHOD'S OWN BODY,
    // from inside the trigger context. Same device as `OpportunityStageEntryService.runQueryCount`
    // and `ExtractAddressQueueable.lastRunQueryCount`.
    //
    // In-transaction only. Not a monitoring surface, never read or reset by production code.
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /** SOQL consumed by this class's own bodies, summed over every invocation in the transaction. */
    @TestVisible
    private static Integer runQueryCount = 0;

    /** DML consumed by this class's own bodies. Must be 0 at any record count, in both contexts. */
    @TestVisible
    private static Integer runDmlCount = 0;

    /** Times a context method was entered. A 251-row DML must produce at least 2 (200-row chunks). */
    @TestVisible
    private static Integer runChunkCount = 0;

    /** Zeroes the instrumentation. Test-only; production never calls it. */
    @TestVisible
    private static void resetRunCounters() {
        runQueryCount = 0;
        runDmlCount = 0;
        runChunkCount = 0;
    }

    /**
     * Clamps `Is_Prerequisite_Met__c` to false on any item being CREATED with a `Blocked_By__c`.
     * Called from `ChecklistItemTriggerHandler.beforeInsert`.
     *
     * 🔴 WHY THIS IS NOT COVERED BY THE FIELD'S DEFAULT VALUE. `<defaultValue>false</defaultValue>`
     * applies only when the field is ABSENT from the insert payload. A writer that SUPPLIES
     * `Is_Prerequisite_Met__c = true` — Data Loader with the column mapped, a Flow assignment, an
     * Apex `insert` — would satisfy every conjunct of `Prerequisite_Must_Be_Met_To_Complete` and
     * create a completed, ungated wire request in one statement. Overwriting the supplied value is
     * the only thing that makes that rule's `ISNEW()` arm mean anything.
     *
     * ⚠ NO LOOKUP HERE, DELIBERATELY, AND THE ASYMMETRY IS THE POINT. Resolving the prerequisite on
     * insert would put a query on the fan-out's before-insert cascade: `ChecklistFanoutService`
     * inserts `CHUNK_SIZE x 82` items in ONE statement, which the platform fires before-insert
     * against in 200-row batches — at `CHUNK_SIZE = 50` that is 4,100 rows and 21 firings, so 21
     * extra SOQL to discover that a freshly created `None` item is not being completed. Clamping
     * to false is strictly fail-closed without needing to know the prerequisite's state, and it is
     * doubly safe here because the fan-out inserts every item with a BLANK `Blocked_By__c` and
     * stamps the links in a second pass (a lookup has no target Id until the rows exist).
     *
     * ⚠ COST FOR EVERY OTHER ITEM: one null check, no query, no DML.
     *
     * @param newItems Trigger.new (`Checklist_Item__c`). Null/empty-safe.
     * @example
     * ChecklistItemPrerequisiteService.clampOnInsert((List<Checklist_Item__c>) newList);
     */
    public static void clampOnInsert(List<Checklist_Item__c> newItems) {
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        try {
            if (newItems == null || newItems.isEmpty()) {
                return;
            }
            for (Checklist_Item__c item : newItems) {
                if (item.Blocked_By__c != null) {
                    item.Is_Prerequisite_Met__c = false;
                }
            }
        } finally {
            // In a finally so an unexpected throw cannot leave the counters reading zero and make
            // a budget assertion pass for the wrong reason.
            runChunkCount++;
            runQueryCount += Limits.getQueries() - queriesBefore;
            runDmlCount += Limits.getDmlStatements() - dmlBefore;
        }
    }

    /**
     * Enforces the prerequisite gate and maintains `Is_Prerequisite_Met__c`, on the records the
     * platform is already saving. Called from `ChecklistItemTriggerHandler.beforeUpdate` only.
     *
     * REFUSES an item ENTERING a done state (`Completed` or `Verified` — see
     * `ChecklistItemDomain.isDone`) while its `Blocked_By__c` target is not itself done. "Entering"
     * is load-bearing and is checked against the STORED prior record:
     *   - prior already done   -> not a transition -> never refused. This is what lets the Phase 4
     *     migration carry across a historically-complete B3 whose B2 was never marked, and what
     *     lets an unrelated edit (comment, due date) to a complete item save normally.
     *   - prior open, new done -> the transition the control exists to police.
     *
     * 🔴 THIS METHOD IS `public` AND IT MUTATES THE RECORDS YOU HAND IT. It sets
     * `Is_Prerequisite_Met__c` on every candidate and enforces ONLY via `SObject.addError`, which
     * the platform honours in a trigger and nowhere else. A future non-trigger caller that passed
     * queried records and ignored the returned map would STAMP THE FLAG AND SAVE IT while refusing
     * nothing — writing the validation rule's own input from outside the control that computes it.
     * IT IS TRIGGER-ONLY BY CONTRACT. `ChecklistItemTriggerHandler` is the sole production caller.
     *
     * @param newItems Trigger.new. Null/empty-safe.
     * @param oldMap   Trigger.oldMap. LOAD-BEARING TWICE: it supplies the prior state for the
     *                 transition test AND the prior `Blocked_By__c` for the surviving-key rule that
     *                 closes SHAPE 1. A null map makes every done record look like a transition and
     *                 forfeits the prior key — fail-closed on the first, permissive on the second,
     *                 which is why the handler always passes `Trigger.oldMap`.
     * @return Refusal messages by item Id — empty when nothing was refused, never null. The handler
     *         ignores it; it exists so a unit test can assert the DECISION without depending on
     *         `addError`, which is only meaningful inside a trigger.
     * @example
     * Map<Id, String> refusals = ChecklistItemPrerequisiteService.enforceOnUpdate(newList, oldMap);
     */
    public static Map<Id, String> enforceOnUpdate(
        List<Checklist_Item__c> newItems,
        Map<Id, Checklist_Item__c> oldMap
    ) {
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        try {
            return enforceChunk(newItems, oldMap);
        } finally {
            runChunkCount++;
            runQueryCount += Limits.getQueries() - queriesBefore;
            runDmlCount += Limits.getDmlStatements() - dmlBefore;
        }
    }

    /**
     * The gate itself. Separated from the public method purely so the instrumentation above can
     * wrap the whole body, including every early return.
     *
     * @param newItems Trigger.new.
     * @param oldMap   Trigger.oldMap.
     * @return Refusal messages by item Id.
     */
    private static Map<Id, String> enforceChunk(
        List<Checklist_Item__c> newItems,
        Map<Id, Checklist_Item__c> oldMap
    ) {
        Map<Id, String> refusals = new Map<Id, String>();
        if (newItems == null || newItems.isEmpty()) {
            return refusals;
        }

        // ── THE COST CONTROL ───────────────────────────────────────────────────────────────
        // Two null checks per item, evaluated FIRST so nothing else is computed for the ~80 of 82
        // items per deal that carry no prerequisite on either side. They leave through the
        // `continue` having spent no query, no DML and nothing that can throw.
        //
        // 🔴 WHICH VALUE THE GATE RESOLVES IS THE ENTIRE SECURITY CONTROL — SHAPES 1 AND 2 IN THE
        // CLASS HEADER. THE RULE: **while the gate is still live on a row, the STORED VALUE WINS.**
        //   - row still OPEN  -> resolve `prior ?? new`. The save cannot choose its own examiner.
        //     (`?? new` matters: an item GAINING its first link — the fan-out's second pass and the
        //     Phase 4 migration — has no prior value to pin.)
        //   - row already DONE -> resolve `new ?? prior`. It is past the gate; ordinary maintenance
        //     and the migration's own corrections must not be refused.
        // This is deliberately WIDER than "while the transition is happening": resolving the stored
        // value on every open row is what also lets branch (B) recognise a DISARMING save at ZERO
        // extra cost, because the resolution it needs is already in hand.
        List<GateCandidate> candidates = new List<GateCandidate>();
        Set<Id> toResolve = new Set<Id>();
        for (Checklist_Item__c item : newItems) {
            Checklist_Item__c prior = (oldMap == null || item.Id == null) ? null : oldMap.get(item.Id);
            Id priorBlockedBy = prior == null ? null : prior.Blocked_By__c;
            if (item.Blocked_By__c == null && priorBlockedBy == null) {
                continue;
            }
            GateCandidate candidate = new GateCandidate();
            candidate.record = item;
            candidate.priorBlockedBy = priorBlockedBy;
            candidate.wasDone = prior != null && ChecklistItemDomain.isDone(prior.Flag__c);
            candidate.entering = !candidate.wasDone && ChecklistItemDomain.isDone(item.Flag__c);
            // Non-null by construction: at least one of the two was non-null to get here.
            candidate.survivingBlockedBy = candidate.wasDone
                ? (item.Blocked_By__c != null ? item.Blocked_By__c : priorBlockedBy)
                : (priorBlockedBy != null ? priorBlockedBy : item.Blocked_By__c);
            // A previously-set link being blanked or repointed. GAINING a link for the first time
            // is NOT a change — that is the fan-out's second pass and the migration, and refusing
            // it would make the feature uninstallable.
            candidate.linkChanged = priorBlockedBy != null && item.Blocked_By__c != priorBlockedBy;
            candidates.add(candidate);
            toResolve.add(candidate.survivingBlockedBy);
            // The candidate's OWN row is resolved in the same query, for its grandparent deal —
            // branch (D) needs it and `Trigger.new` carries only the `Checklist__c` lookup.
            if (item.Id != null) {
                toResolve.add(item.Id);
            }
            // And the value being WRITTEN, which on an open row is NOT the value the gate
            // resolves (stored wins). Branch (D) judges the write itself, so it needs the written
            // target's parentage. Adding an Id to a set already being queried costs nothing —
            // still exactly one query for the whole chunk.
            if (item.Blocked_By__c != null) {
                toResolve.add(item.Blocked_By__c);
            }
        }
        if (candidates.isEmpty()) {
            return refusals;
        }

        // EXACTLY ONE QUERY, for candidates and prerequisites together.
        Map<Id, Checklist_Item__c> resolved = ChecklistItemSelector.selectByIdsWithDeal(toResolve);

        for (GateCandidate candidate : candidates) {
            Checklist_Item__c item = candidate.record;
            Checklist_Item__c prerequisite = resolved.get(candidate.survivingBlockedBy);
            Checklist_Item__c storedSelf = resolved.get(item.Id);

            // SELF-REFERENCE. A self-lookup permits it and no platform rule forbids it; an item
            // that blocks itself would otherwise be permanently uncompletable with no explanation.
            Boolean selfReference = candidate.survivingBlockedBy == item.Id;
            // CROSS-DEAL. Both sides come from the DATABASE, never from Trigger.new — the
            // candidate's own parentage is stored and (being non-reparentable master-detail)
            // cannot be moved by this save, so reading it from the query is not merely tidy, it is
            // the only value that can be trusted.
            Boolean sameDeal = prerequisite != null
                && storedSelf != null
                && prerequisite.Checklist__r.Transaction__c != null
                && prerequisite.Checklist__r.Transaction__c == storedSelf.Checklist__r.Transaction__c;

            Boolean met = prerequisite != null
                && !selfReference
                && sameDeal
                && ChecklistItemDomain.isDone(prerequisite.Flag__c);

            // Denormalised backstop for the validation rule. A before-context assignment needs no
            // FLS grant of its own, so a freshly deployed field with zero FieldPermissions cannot
            // break an unrelated save through this line.
            // 🔴 THIS STAMP IS THE RULE'S OWN INPUT, which is why SHAPE 2 mattered so much on the
            // Task model: a resolution against an attacker-chosen target does not merely fail to
            // refuse here, it actively DISARMS the rule. The stamp is only ever as trustworthy as
            // `survivingBlockedBy`.
            item.Is_Prerequisite_Met__c = met;

            // The target this save is WRITING, which on an open row differs from the one the gate
            // resolves. Null when the save writes no link, or writes one that cannot be seen.
            Checklist_Item__c written = item.Blocked_By__c == null
                ? null
                : resolved.get(item.Blocked_By__c);

            String message = refusalFor(candidate, prerequisite, met, selfReference, sameDeal,
                storedSelf, written);
            if (message == null) {
                continue;
            }
            refusals.put(item.Id, message);

            // `addError` is documented as valid in trigger context only. Guarded so the direct unit
            // tests (which have no trigger to run inside) assert the returned map instead of
            // depending on undefined behaviour. Every DML-driven test exercises this line for real.
            if (Trigger.isExecuting) {
                item.addError(message);
            }
        }
        return refusals;
    }

    /**
     * The refusal message for one candidate, or null to allow the save. FOUR branches answering
     * four different questions — do not collapse them.
     *
     * (A) COMPLETING WHILE UNMET. The primary control: the item is entering a done state and its
     *     prerequisite is not done, is unresolvable, is itself, or belongs to another deal. Fails
     *     CLOSED in every one of those cases. HAS NO OVERRIDE AND NEVER WILL — the override permits
     *     maintaining the gate's link, never completing past an open prerequisite.
     *
     * (D) POINTING THE LINK SOMEWHERE ILLEGITIMATE. NEW ON THIS MODEL (see SHAPE 2). A save that
     *     sets `Blocked_By__c` to the item itself, or to an item under a different Transaction, is
     *     refused outright whatever else it does. Without this, a lookup would be a strictly WIDER
     *     attack surface than the Phase 0 text key, which could only ever name a same-deal sibling.
     *     Deliberately evaluated on the value being WRITTEN (`record.Blocked_By__c`), because a
     *     pre-existing bad link must stay REPAIRABLE — it already fails closed through (A).
     *
     * (B) DISARMING A LIVE GATE. The item is not being completed, is STILL OPEN, and this save
     *     blanks or repoints a link whose stored target is an OPEN prerequisite on the same deal.
     *     This is the first save of the two-save bypass: disarm now, complete in a separate save,
     *     by which point neither `Trigger.old` nor the validation rule has anything left to
     *     resolve. Refusing the disarm is the only place that sequence can be stopped, and it costs
     *     nothing — the resolution is the one branch (A) already needed.
     *
     * ⚠ (B) IS DELIBERATELY NARROW, AND EACH NARROWING KEEPS SOMETHING WORKING:
     *   - `!wasDone` — an already-done item is past the gate, so its link stays editable. This is
     *     what keeps the Phase 4 migration and ordinary maintenance working.
     *   - `prerequisite != null && sameDeal` — an UNRESOLVABLE or already-illegitimate link stays
     *     REPAIRABLE. Without this the feature could brick the very data it depends on with no
     *     route back. (`prerequisite == null` is self-exempting; a wrong-but-RESOLVABLE link is
     *     not, which is exactly why `Transaction_Prereq_Override` exists — see below.)
     *   - `!met` — once the verification is done there is nothing left to protect.
     *   - `linkChanged` — an ordinary edit to an open gated item (comment, due date, owner label)
     *     moves nothing. In a before-update `Trigger.new` carries the STORED value for any field
     *     the caller did not write, so this is false for every unrelated save.
     *   - `!hasPrereqOverrideAccess()` — the administrative escape hatch.
     *
     * ⚠ THE CONSEQUENCE, STATED SO IT IS NOT MET AS A BUG: while B2 is open, a principal WITHOUT
     * `Transaction_Prereq_Override` cannot change or remove B3's link. That is the point of an
     * armed control.
     * ⚠ `FeatureManagement.checkPermission` returns false for an UNDEPLOYED permission and never
     * throws, so if this class ever shipped without `Transaction_Prereq_Override` and its
     * permission set, the escape hatch would silently not exist and every link change on an open
     * row would be refused with nothing explaining why. They belong in the same deploy. (Both
     * already exist in this repo — Phase 0 shipped them — which is why Phase 2 adds no new
     * custom permission.)
     *
     * @param candidate     The item being saved, with its surviving link and its prior state.
     * @param prerequisite  The resolved prerequisite, or null when the link resolved to nothing.
     * @param met           Whether that prerequisite is done, same-deal and not the item itself.
     * @param selfReference Whether the surviving link points at the item itself.
     * @param sameDeal      Whether the resolved prerequisite belongs to the item's own Transaction.
     * @param storedSelf    The candidate's own row as STORED, carrying its grandparent deal. Never
     *                      taken from `Trigger.new` — see the cross-deal note in `enforceChunk`.
     * @param written       The row this save's `Blocked_By__c` points at, or null when the save
     *                      writes no link or points at a row that cannot be resolved.
     * @return The user-facing refusal, or null when the save is allowed.
     */
    private static String refusalFor(
        GateCandidate candidate,
        Checklist_Item__c prerequisite,
        Boolean met,
        Boolean selfReference,
        Boolean sameDeal,
        Checklist_Item__c storedSelf,
        Checklist_Item__c written
    ) {
        // (A) — the primary control. No exemption, ever.
        if (candidate.entering && !met) {
            if (selfReference || (prerequisite != null && !sameDeal)) {
                return MSG_CROSS_DEAL;
            }
            if (prerequisite == null) {
                return MSG_UNRESOLVED;
            }
            // DISPLAY ONLY. The Subject names the blocking step for the user; no branch reads it.
            // Unquoted on purpose: `addError` HTML-escapes, so quotes would render as `&quot;`.
            return MSG_BLOCKED
                + (String.isBlank(prerequisite.Subject__c)
                    ? 'the preceding checklist item'
                    : prerequisite.Subject__c)
                + '.';
        }

        // (D) — refuse WRITING an illegitimate link, whatever else the save does. Judged on the
        // value being WRITTEN this save, never on a pre-existing one: a bad stored link must stay
        // REPAIRABLE (it already fails closed through (A)), and refusing every unrelated edit to
        // such a row would brick it instead.
        Boolean writingLink = candidate.record.Blocked_By__c != null
            && candidate.record.Blocked_By__c != candidate.priorBlockedBy;
        if (writingLink) {
            if (candidate.record.Blocked_By__c == candidate.record.Id) {
                return MSG_CROSS_DEAL;
            }
            if (written == null) {
                // Points at a row that does not exist, or that this principal cannot see. Fails
                // CLOSED rather than being written and discovered later by branch (A).
                return MSG_UNRESOLVED;
            }
            if (storedSelf != null
                    && written.Checklist__r.Transaction__c != storedSelf.Checklist__r.Transaction__c) {
                return MSG_CROSS_DEAL;
            }
        }

        // (B) — refuse disarming a live gate.
        if (!candidate.wasDone
                && !met
                && prerequisite != null
                && sameDeal
                && candidate.linkChanged
                && !TransactionActionPermissionService.hasPrereqOverrideAccess()) {
            return MSG_DISARM;
        }
        return null;
    }

    /**
     * One item under examination, with everything decided about it BEFORE the query — so the
     * verdict loop cannot silently re-derive a different answer from the one the resolution was
     * performed against. Built once in `enforceChunk`; there is exactly one construction site.
     *
     * 🔴 THERE IS EXACTLY ONE COORDINATE ON THIS MODEL (`survivingBlockedBy`), WHERE PHASE 0 HAD
     * TWO (`survivingKey` + `survivingDealId`) THAT HAD TO MOVE TOGETHER. That is the whole reason
     * SHAPES 3a and 3b are dead here. If a second coordinate is ever added — a scope, a version, a
     * date — it must be pinned in the same breath as this one, or the bypass simply relocates to
     * whichever part is still read from `Trigger.new`. That is the Phase 0 lesson in one sentence.
     */
    private class GateCandidate {
        /** The item as it is being saved (a `Trigger.new` member). */
        Checklist_Item__c record;
        /** `Blocked_By__c` as STORED, from `Trigger.old`. Null when the item had no link. */
        Id priorBlockedBy;
        /** The stored record's done-ness, from `Trigger.old` — authoritative. */
        Boolean wasDone;
        /** Open -> done transition. */
        Boolean entering;
        /** Stored-wins while the row is open. Never null (a candidate had one on some side). */
        Id survivingBlockedBy;
        /** This save blanks or repoints a link that already existed. */
        Boolean linkChanged;
    }

    /**
     * Raised by `asRefusal` so an LWC boundary can surface a prerequisite refusal VERBATIM instead
     * of a controller's generic "could not be updated, refresh and try again".
     *
     * 🔴 WHY A TRANSLATION AND NOT A THROW. The refusal itself must stay an `addError` on the
     * record: an exception thrown from a before trigger aborts the WHOLE transaction, which would
     * turn a partial-success `Database.update(list, false)` of 251 items into an all-or-nothing
     * one. So the platform hands callers a `DmlException`, and `ChecklistItemService` translates it
     * back into this type. The translation lives beside the constants it matches so the two cannot
     * drift.
     */
    public class PrerequisiteNotMetException extends Exception {}

    /**
     * Recognises this class's own refusal inside a `DmlException` and re-types it.
     *
     * Matched against the constants that PRODUCED the text rather than a marker token embedded in
     * the user-facing message — a marker would either leak into the message every non-LWC caller
     * sees (Data Loader, REST, Flow) or need stripping in two places.
     * ⚠ ADD ANY NEW REFUSAL CONSTANT TO THIS LIST IN THE SAME CHANGE. A missing entry does not
     * throw; the refusal simply reverts to the caller's generic message, on the one path a human
     * uses, with nothing in the log to explain it.
     *
     * @param e The DmlException raised by a save this gate refused; null-safe.
     * @return A `PrerequisiteNotMetException` carrying the user-facing text, or null when `e` is
     *         something else entirely — in which case the caller must NOT surface it verbatim.
     * @example
     * PrerequisiteNotMetException refusal = ChecklistItemPrerequisiteService.asRefusal(e);
     */
    public static PrerequisiteNotMetException asRefusal(DmlException e) {
        if (e == null) {
            return null;
        }
        for (Integer i = 0; i < e.getNumDml(); i++) {
            String dmlMessage = e.getDmlMessage(i);
            if (String.isBlank(dmlMessage)) {
                continue;
            }
            if (dmlMessage.contains(MSG_BLOCKED)
                    || dmlMessage.contains(MSG_UNRESOLVED)
                    || dmlMessage.contains(MSG_DISARM)
                    || dmlMessage.contains(MSG_CROSS_DEAL)) {
                return new PrerequisiteNotMetException(dmlMessage);
            }
        }
        return null;
    }
}
