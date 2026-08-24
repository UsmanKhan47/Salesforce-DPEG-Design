/**
 * Enforces BOV SELECTION EXCLUSIVITY on `BOV_Submission__c` as a BEFORE-CONTEXT TRIGGER GUARD that
 * REFUSES the offending save. Added 2026-08-20 with the disposition redesign, Tranche 2 Workstream
 * A2 (`agent-output/disposition-tranche-2-requirements.md` §1.2, constraint solution 1).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE INVARIANT CHANGED ON 2026-08-24 (USER DECISION). READ THIS BLOCK BEFORE ANYTHING ELSE.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ RETRACTED IN PLACE, NOT DELETED, because the old rule is quoted verbatim in five other class
 * headers, in `DispositionApprovalService.MULTIPLE_SELECTED_BOV_MESSAGE`, in this repo's test
 * names, and in the design document — a reader WILL meet it again and must be able to tell which
 * sentence is current.
 *
 *   THE OLD RULE (2026-08-20 -> 2026-08-24):
 *   > "AT MOST ONE `Submission_Status__c = 'Selected'` BOV submission per Disposition."
 *
 *   THE RULE NOW:
 *   > **AT MOST ONE SELECTED *PREFERRED* SUBMISSION, AND AT MOST ONE SELECTED *NON-PREFERRED*
 *   > SUBMISSION, PER DISPOSITION.** Two Selected rows on one sale is now a NORMAL, EXPECTED
 *   > state — the scored winner the model picked, and the preferred broker a human named. THREE
 *   > is still refused, and so is a second of either kind.
 *
 * 🔴 THIS IS A CONTROL BEING **NARROWED**, NOT REMOVED, AND THE DISTINCTION IS THE WHOLE POINT.
 * Deleting the guard because "two Selected rows are allowed now" would let a data load, a
 * hand-crafted API call or a future component leave a disposition with three or four Selected
 * brokers — the exact state this class was written to prevent, and the state
 * `DispositionApprovalService`'s BOV Outreach branch cannot resolve into "which broker did the
 * business appoint?". The guard still answers that question; it now answers it TWICE, once per
 * slot.
 *
 * ── 🔴 WHY THE COUNTING KEY IS `Submission_Status__c` **AND** `Is_Preferred_Broker__c`, AND NOT
 *      `Is_System_Selected__c` AS THE CHANGE REQUEST LITERALLY SAID ────────────────────────────
 * The requirement was phrased "at most ONE system-selected AND at most ONE preferred", i.e. count
 * the two flags. Counting `Is_System_Selected__c` for the second slot HAS A HOLE, and it is a live
 * one rather than a theoretical one:
 *
 *   `BovSubmissionService.replaceSelectedBroker` promotes a challenger to `Selected` with
 *   `Is_Manually_Appointed__c = true` and NO `Is_System_Selected__c` — a manual appointment is not
 *   a scoring pick, and the field's own XML says `BovAutoSelectionService` is its ONLY writer. So a
 *   manually appointed row is invisible to BOTH flag counters, and TWO of them on one disposition
 *   would be permitted. That is precisely the ambiguity the guard exists to refuse.
 *
 * So the second slot is counted as **Selected AND NOT preferred**, which is a strict SUPERSET of
 * "system-selected": it refuses two scored winners (both are non-preferred), two manual
 * appointments, and one of each. `Is_System_Selected__c` remains the field that TELLS THE TWO
 * SELECTED ROWS APART for readers and for reporting; it is deliberately not the field this guard
 * counts. `twoManuallyAppointedRows_areRefusedEvenThoughNeitherIsSystemSelected` is the falsifier
 * and must not be deleted.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY A TRIGGER AT ALL — THE TWO OBVIOUS MECHANISMS ARE BOTH UNAVAILABLE
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * Until this class existed the invariant was guaranteed ONLY by service code
 * (`BovSubmissionService.replaceSelectedBroker`). Nothing stopped the API, a data loader,
 * anonymous Apex or a hand edit from creating two — and `BOV_Submission__c.Submission_Status__c` is
 * granted READ + EDIT in `DPEG_Disposition_Edit`, so it is breakable BY HAND today. That is what
 * makes this the high-value half of the pair; the `Disposition_Offer__c` twin closes a narrower,
 * API-only residual (see `DispositionOfferSelectionGuardService`).
 *
 *   A VALIDATION RULE CANNOT DO IT. A VR evaluates against the single record being saved and has no
 *   access to sibling rows. `Disposition__c.NDA_Count__c`'s own field header states the general form
 *   of this: "a validation rule cannot count children."
 *
 *   A ROLL-UP SUMMARY CANNOT DO IT. Roll-ups require Master-Detail, and EVERY child -> Disposition__c
 *   relationship in this module is a LOOKUP.
 *
 *   A MAINTAINED COUNTER + VR (the `NDA_Count__c` / `NDA_Signed_Rollup` shape) WAS CONSIDERED AND
 *   REJECTED. A counter written by an after-save automation is only EVENTUALLY correct: the VR that
 *   reads it fires on the NEXT save, not on the offending one. That is fine for a stage gate, which
 *   is what the NDA counters are, and useless for an EXCLUSIVITY invariant, which must refuse the
 *   save that breaks it. It would also add two derived fields and a second automation to keep in
 *   sync.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 IT REFUSES. IT DOES NOT SELF-HEAL. THIS IS THE CENTRAL DECISION OF THE CLASS.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `BovSubmissionService.replaceSelectedBroker` DOES self-heal — it demotes every currently-Selected
 * non-preferred sibling — and that is correct THERE and wrong HERE, for four reasons:
 *
 *   1. THE SERVICE WAS ASKED TO CHANGE THE APPOINTMENT. A trigger was not. A blind self-heal
 *      silently demotes a sibling the user never named, inside a save that was about something else.
 *
 *   2. 🔴 A CORRECT SELF-HEAL CANNOT BE A ONE-FIELD WRITE. Demoting a submission WITHOUT also
 *      clearing its `Approval_Status__c` recreates precisely the state `replaceSelectedBroker`
 *      exists to prevent — an 'Approved' status on a broker who is no longer appointed, which
 *      "reads as an appointment nobody made" (that class's header). So the trigger would have to
 *      perform a SECOND, CONSEQUENTIAL write with NO ACTOR, NO REASON and NO AUDIT TRAIL — while
 *      Workstream B is being built specifically because that gap is unacceptable. Self-healing here
 *      would create the exact defect B is fixing.
 *
 *   3. REFUSAL IS THE ONLY SAFE ANSWER TO A BULK LOAD. A data loader pushing 500 rows with three
 *      Selected on one disposition should be told WHICH ROWS ARE WRONG, not silently have two of
 *      them rewritten. `addError` on a before-context row does exactly that, per row.
 *
 *   4. THE SELF-HEAL ALREADY EXISTS AT THE ONE PLACE IT BELONGS. A second, weaker copy in a trigger
 *      would give the codebase two disagreeing owners of one invariant.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE EVALUATION RULE, AND THE THREE CONSEQUENCES THAT ARE LOAD-BEARING
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * > Error ONLY on a record that is TAKING A SLOT — inserted as Selected, changed to Selected, or
 * > already Selected and moving INTO this slot (its parent changed, or its preferred flag flipped)
 * > — when, AFTER APPLYING EVERY INCOMING ROW'S NEW VALUE IN MEMORY, another row still holds THE
 * > SAME SLOT on the same Disposition.
 *
 * The "after applying every incoming row's new value" clause is the whole design. A before-trigger's
 * SOQL reads COMMITTED data, so a demoted incumbent still reads 'Selected' in the database; the
 * in-memory value of any row present in this chunk therefore SUPERSEDES its database row.
 *
 *   1. 🔴 THE EXISTING SERVICES MUST STILL SUCCEED, AND THEY DO — STRUCTURALLY, NOT BY LUCK.
 *      `BovSubmissionService.replaceSelectedBroker` demotes the incumbent and promotes the
 *      challenger in ONE bulk `Database.update(writes, ...)`. A before-update context therefore sees
 *      BOTH rows in `Trigger.new`, the incumbent's in-memory 'Backup' supersedes its committed
 *      'Selected', and the challenger finds no remaining occupant of its slot. If that service is
 *      ever split into two DML statements it WILL start being refused here — which is the correct
 *      alarm, not a regression to work around.
 *      `existingReplaceSelectedBrokerService_stillSucceeds` in the test class is the falsifier and
 *      must never be deleted.
 *
 *   2. A ROW ALREADY HOLDING ITS SLOT, SAVED FOR AN UNRELATED REASON, IS NEVER BLOCKED. It is not
 *      TAKING the slot, so it is never even evaluated and the guard costs zero queries. Without
 *      this, a pre-existing double-Selected pair would become permanently unsavable — FROZEN —
 *      which is the failure mode `Broker_Lookup_Is_Off_Market_Only`'s header argues at length must
 *      be avoided ("an unguarded rule cannot trap a record here, and that is what makes it safe").
 *      ⚠ THIS IS ALSO WHY NO TEST CONSTRUCTS A GENUINE PRE-EXISTING PAIR: once this guard is live
 *      that state is unreachable, and the fast path means a pair is never evaluated at all. Adding a
 *      `@TestVisible` bypass switch purely to build such a fixture would put a production-reachable
 *      escape hatch in this class to prove a branch that does not exist. It was considered and
 *      rejected.
 *
 *   3. ANY SAVE THAT REDUCES A SLOT'S OCCUPANCY IS ALWAYS PERMITTED. That is the remedy path out of
 *      a bad state, and a guard that blocks the remedy is worse than no guard. It falls out of the
 *      same fast path: a demotion makes no row take a slot.
 *
 * ── ⚠ TWO DELIBERATE EXTENSIONS OF THE WRITTEN RULE ─────────────────────────────────────────
 * REPARENTING. A row that is ALREADY Selected and whose `Disposition__c` CHANGES arrives Selected on
 * a disposition it was not previously Selected on. Its status never "changed to Selected", so a rule
 * written only about status would let it create the second occupant this class exists to prevent.
 * `reparentingASelectedRowOntoAnOccupiedDisposition_isRejected` pins it.
 *
 * SLOT CHANGE (added 2026-08-24 with the two-slot invariant). A row that is ALREADY Selected and
 * whose `Is_Preferred_Broker__c` FLIPS moves from one slot to the other, and arrives in a slot it
 * did not previously hold — the identical shape as reparenting, one field over. Without this clause,
 * flagging an already-Selected scored winner as preferred on a sale that already has a Selected
 * preferred broker would produce two Selected preferred rows.
 * `flippingAnAlreadySelectedRowIntoAnOccupiedPreferredSlot_isRejected` pins it.
 *
 * ── BUDGET / BULK ───────────────────────────────────────────────────────────────────────────
 * **AT MOST 1 SOQL AND EXACTLY 0 DML PER CHUNK — CONSTANT IN THE NUMBER OF SUBMISSIONS.** No SOQL
 * and no DML inside any loop; the one query is keyed on the `Set<Id>` of parent dispositions drawn
 * from the rows that are taking a slot.
 *
 * 🔴 ZERO-QUERY FAST PATH. A chunk in which NO row takes a slot returns BEFORE the query. That is
 * what keeps this guard invisible to the 251-record bulk tests of every unrelated feature — the same
 * "an ordinary save costs nothing" contract `BovSubmissionBrokerStampService` already carries on
 * these very contexts.
 *
 * 🔴 `.claude/rules/bulk-test-rule.md`'s 251-RECORD MANDATE APPLIES IN FULL AND THERE IS NO
 * EXEMPTION TO CLAIM. This is a trigger path and it loops over a collection.
 *
 * ── LAYERING ────────────────────────────────────────────────────────────────────────────────
 * Service (`layer=service`, ARCHITECTURE.md §2). It CANNOT be a Domain method: the decision needs a
 * SIBLING READ, and `.claude/rules/apex-layering-rule.md` gives Domain classes zero SOQL. ZERO
 * inline SOQL here either — the read goes to `BovSubmissionSelector.selectSelectedByDispositionIds`.
 * ZERO DML at any record count: `addError` is not a write.
 *
 * ── SHARING / MODE ──────────────────────────────────────────────────────────────────────────
 * `with sharing`. The selector read is `WITH SYSTEM_MODE`, justified at its own declaration on
 * ARCHITECTURE.md §2 automation-path grounds: the running user asked to SAVE A SUBMISSION, not to
 * read its siblings, and `USER_MODE` THROWS rather than degrades — inside a before-trigger that
 * throw escapes as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and rolls back the user's own save.
 *
 * 🔴 SHARING IS A SEPARATE QUESTION AND THE ANSWER IS "LEAVE IT ALONE". `SYSTEM_MODE` lifts CRUD and
 * FLS and NEVER sharing. `BOV_Submission__c` is `sharingModel Private`, but every row in scope hangs
 * off a disposition the running user is currently editing — this is NOT the
 * `InboundEmailStagingSelector.RoutingReads` shape (rows owned by a different principal), so no
 * `without sharing` inner class is added.
 * ⚠ THE ASYMMETRY THAT CREATES IS NAMED RATHER THAN HIDDEN: a sharing-filtered read that MISSES a
 * Selected sibling INVERTS this guard into a PERMITTER — it fails open, not closed. That residual is
 * bounded by two facts: this guard is defence in depth BEHIND an authored service that is still the
 * primary enforcement, and both `DPEG_Disposition_Edit` and `DPEG_Disposition_View` carry
 * `viewAllRecords = true` on the disposition child objects, so for the two personas this module
 * exists for there is nothing hidden to miss.
 *
 * @see force-app/main/default/classes/BovSubmissionTriggerHandler.cls (the only caller)
 * @see force-app/main/default/classes/BovSubmissionSelector.cls (the ONE query)
 * @see force-app/main/default/classes/BovAutoSelectionService.cls (the writer of BOTH slots)
 * @see force-app/main/default/classes/BovSubmissionService.cls (the authored self-heal, and why this
 *      class must not copy it)
 * @see force-app/main/default/classes/DispositionOfferSelectionGuardService.cls (the twin)
 */
public with sharing class BovSubmissionSelectionGuardService {

    /**
     * The `Submission_Status__c` value marking an appointed broker. `Submission_Status__c` is
     * RESTRICTED to exactly {Backup, Selected}, so this is half the value set. Each layer holds its
     * own copy (`BovSubmissionService`, `BovSubmissionTriggerHandler`, `BovSubmissionSelector`);
     * this one is the guard's.
     */
    @TestVisible
    private static final String STATUS_SELECTED = 'Selected';

    /** The two slots a Selected row can occupy. Used only to key the per-slot counters below. */
    private static final String SLOT_PREFERRED = 'PREFERRED';
    private static final String SLOT_APPOINTED = 'APPOINTED';

    /**
     * The refusal for a SECOND SELECTED NON-PREFERRED row, surfaced verbatim to whoever attempted
     * the save — a user in the UI, a row error in the Bulk API, an exception in anonymous Apex.
     *
     * 🔴 IT NAMES BOTH REMEDIES, WHICH IS WHAT MAKES IT ACTIONABLE. "Only one may be Selected" alone
     * would tell a user they are wrong without telling them what to do; the whole reason this is a
     * refusal rather than a self-heal is that a HUMAN must decide which broker is appointed.
     *
     * ⚠ RE-AUTHORED 2026-08-24. It used to say "already has a Selected broker response", which is
     * now MISLEADING rather than merely imprecise: a disposition legitimately has two Selected
     * responses, and a user reading the old sentence next to a screen showing a Selected preferred
     * broker would reasonably conclude the message was a bug. It now names the KIND of row that
     * collides.
     */
    @TestVisible
    private static final String DUPLICATE_APPOINTED_MESSAGE =
        'This disposition already has a Selected broker response that is not a preferred broker, '
        + 'and only one is allowed. Use the Replace Broker action on the Disposition, or set the '
        + 'current Selected response to Backup in the same save.';

    /**
     * The refusal for a SECOND SELECTED PREFERRED row. A SEPARATE constant rather than a shared
     * one, deliberately: the two halves of the invariant have DIFFERENT remedies (Replace Broker
     * does not operate on preferred rows — the way to change a preferred broker is Add Preferred
     * Broker, which retires the outgoing one), and a shared message would send half the users to a
     * button that refuses them. It is also what lets the two mutation tests
     * (`...twoAppointed...` / `...twoPreferred...`) redden INDEPENDENTLY.
     */
    @TestVisible
    private static final String DUPLICATE_PREFERRED_MESSAGE =
        'This disposition already has a Selected preferred broker, and only one is allowed. '
        + 'Use Add Preferred Broker on the BOV comparison matrix, which replaces the current '
        + 'preferred broker and records the change, or set the current one to Backup in the same '
        + 'save.';

    /**
     * Refuses any save that would leave a Disposition with more than one Selected PREFERRED
     * submission, or more than one Selected NON-PREFERRED submission. Mutates nothing and performs
     * no DML — it either returns silently or calls `addError` on the offending rows.
     *
     * ⚠ RENAMED from `enforceSingleSelected` on 2026-08-24. The old name asserted the OLD invariant
     * ("single Selected"), which is now false — and a method whose name contradicts its body is the
     * defect this rename exists to prevent, not churn. `BovSubmissionTriggerHandler` is the only
     * caller.
     *
     * @param incoming Trigger.new. Null/empty-safe.
     * @param oldMap   Trigger.oldMap on update; NULL ON INSERT — on insert every Selected row counts
     *                 as taking its slot, which is the correct reading.
     * @example
     * BovSubmissionSelectionGuardService.enforceSelectionExclusivity(newList, oldMap);
     */
    public static void enforceSelectionExclusivity(
        List<BOV_Submission__c> incoming,
        Map<Id, BOV_Submission__c> oldMap
    ) {
        if (incoming == null || incoming.isEmpty()) {
            return;
        }

        // ── PASS 1 — classify, entirely in memory. ────────────────────────────────────────────
        // `takingASlot`      the rows to JUDGE.
        // `incomingBySlot`   how many incoming rows will END Selected per (disposition, slot) —
        //                    this is the "after applying every incoming row's new value" half.
        // `incomingIds`      EVERY incoming row's Id, including rows being demoted: the database
        //                    still reports them Selected, and their in-memory value must win.
        List<BOV_Submission__c> takingASlot = new List<BOV_Submission__c>();
        Set<Id> parentIds = new Set<Id>();
        Map<String, Integer> incomingBySlot = new Map<String, Integer>();
        Set<Id> incomingIds = new Set<Id>();

        for (BOV_Submission__c submission : incoming) {
            if (submission.Id != null) {
                incomingIds.add(submission.Id);
            }
            // A submission with no parent has no siblings, so there is no invariant to enforce.
            if (submission.Disposition__c == null) {
                continue;
            }
            if (!STATUS_SELECTED.equals(submission.Submission_Status__c)) {
                continue;
            }
            Boolean preferredNow = submission.Is_Preferred_Broker__c == true;
            bump(incomingBySlot, slotKey(submission.Disposition__c, preferredNow));

            BOV_Submission__c prior = (oldMap == null || submission.Id == null)
                ? null
                : oldMap.get(submission.Id);
            // "Already holding THIS slot ON THIS DISPOSITION" — see the TWO DELIBERATE EXTENSIONS
            // note in the class header for why the parent AND the preferred flag are part of the
            // test rather than only the status.
            Boolean wasAlreadyHoldingThisSlot = prior != null
                && STATUS_SELECTED.equals(prior.Submission_Status__c)
                && prior.Disposition__c == submission.Disposition__c
                && (prior.Is_Preferred_Broker__c == true) == preferredNow;
            if (!wasAlreadyHoldingThisSlot) {
                takingASlot.add(submission);
                parentIds.add(submission.Disposition__c);
            }
        }

        if (takingASlot.isEmpty()) {
            // 🔴 THE ZERO-QUERY FAST PATH, and the reason consequences 2 and 3 in the class header
            // hold: an ordinary save, and ANY save that only reduces occupancy, stops here.
            return;
        }

        // ── PASS 2 — ONE query for the whole chunk, never one per record. ─────────────────────
        // Rows present in this chunk are SKIPPED: the database reports their committed value, and
        // the in-memory value already counted in PASS 1 supersedes it. This single line is what
        // lets `replaceSelectedBroker`'s and `BovAutoSelectionService`'s demote-and-promote pass.
        Map<String, Integer> committedBySlot = new Map<String, Integer>();
        for (BOV_Submission__c sibling
                : BovSubmissionSelector.selectSelectedByDispositionIds(parentIds)) {
            if (incomingIds.contains(sibling.Id)) {
                continue;
            }
            bump(
                committedBySlot,
                slotKey(sibling.Disposition__c, sibling.Is_Preferred_Broker__c == true)
            );
        }

        // ── PASS 3 — judge, ONE SLOT AT A TIME. In-memory only; `addError` is not a write. ────
        for (BOV_Submission__c submission : takingASlot) {
            Boolean preferredNow = submission.Is_Preferred_Broker__c == true;
            String slot = slotKey(submission.Disposition__c, preferredNow);
            Integer committed = committedBySlot.get(slot);
            Integer incomingSelected = incomingBySlot.get(slot);
            // `- 1` excludes the row being judged, which PASS 1 counted in `incomingBySlot`.
            Integer others = (committed == null ? 0 : committed) + incomingSelected - 1;
            if (others > 0) {
                // FIELD-LEVEL, naming the field the user must change. The platform bubbles a field
                // error to the page-level error area when the field is not on the layout, and
                // returns it as the row's error in the Bulk API — so nothing is lost on the
                // API-only paths this guard mainly exists for.
                submission.Submission_Status__c.addError(
                    preferredNow ? DUPLICATE_PREFERRED_MESSAGE : DUPLICATE_APPOINTED_MESSAGE
                );
            }
        }
    }

    /**
     * The counter key: one disposition has TWO independent slots, so the Id alone cannot key it.
     *
     * @param dispositionId the parent; never null at either call site.
     * @param preferred     true for the PREFERRED slot, false for the APPOINTED (non-preferred) one.
     * @return a composite key unique per (disposition, slot).
     */
    private static String slotKey(Id dispositionId, Boolean preferred) {
        return String.valueOf(dispositionId) + '|' + (preferred ? SLOT_PREFERRED : SLOT_APPOINTED);
    }

    /**
     * Increments a slot counter, treating a missing entry as zero.
     *
     * @param counters the map to mutate; never null.
     * @param key      the slot key from `slotKey`.
     */
    private static void bump(Map<String, Integer> counters, String key) {
        Integer running = counters.get(key);
        counters.put(key, running == null ? 1 : running + 1);
    }
}
