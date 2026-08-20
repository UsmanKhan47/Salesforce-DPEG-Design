/**
 * Enforces "AT MOST ONE `Submission_Status__c = 'Selected'` BOV submission per Disposition" as a
 * BEFORE-CONTEXT TRIGGER GUARD that REFUSES the offending save. Added 2026-08-20 with the
 * disposition redesign, Tranche 2 Workstream A2 (`agent-output/disposition-tranche-2-requirements.md`
 * §1.2, constraint solution 1).
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
 * sibling — and that is correct THERE and wrong HERE, for four reasons:
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
 * > Error ONLY on a record being INSERTED AS Selected, or CHANGED TO Selected, when — AFTER
 * > APPLYING EVERY INCOMING ROW'S NEW VALUE IN MEMORY — another Selected sibling remains on the
 * > same Disposition.
 *
 * The "after applying every incoming row's new value" clause is the whole design. A before-trigger's
 * SOQL reads COMMITTED data, so a demoted incumbent still reads 'Selected' in the database; the
 * in-memory value of any row present in this chunk therefore SUPERSEDES its database row.
 *
 *   1. 🔴 THE EXISTING SERVICES MUST STILL SUCCEED, AND THEY DO — STRUCTURALLY, NOT BY LUCK.
 *      `BovSubmissionService.replaceSelectedBroker` demotes the incumbent and promotes the
 *      challenger in ONE bulk `Database.update(writes, ...)`. A before-update context therefore sees
 *      BOTH rows in `Trigger.new`, the incumbent's in-memory 'Backup' supersedes its committed
 *      'Selected', and the challenger finds no remaining Selected sibling. If that service is ever
 *      split into two DML statements it WILL start being refused here — which is the correct alarm,
 *      not a regression to work around. `existingReplaceSelectedBrokerService_stillSucceeds` in the
 *      test class is the falsifier and must never be deleted.
 *
 *   2. A ROW ALREADY SELECTED, SAVED FOR AN UNRELATED REASON, IS NEVER BLOCKED. It is not BECOMING
 *      Selected, so it is never even evaluated and the guard costs zero queries. Without this, a
 *      pre-existing double-Selected pair would become permanently unsavable — FROZEN — which is the
 *      failure mode `Broker_Lookup_Is_Off_Market_Only`'s header argues at length must be avoided
 *      ("an unguarded rule cannot trap a record here, and that is what makes it safe").
 *      ⚠ THIS IS ALSO WHY NO TEST CONSTRUCTS A GENUINE PRE-EXISTING PAIR: once this guard is live
 *      that state is unreachable, and the fast path means a pair is never evaluated at all. Adding a
 *      `@TestVisible` bypass switch purely to build such a fixture would put a production-reachable
 *      escape hatch in this class to prove a branch that does not exist. It was considered and
 *      rejected.
 *
 *   3. ANY SAVE THAT REDUCES THE SELECTED COUNT IS ALWAYS PERMITTED. That is the remedy path out of
 *      a bad state, and a guard that blocks the remedy is worse than no guard. It falls out of the
 *      same fast path: a demotion makes no row BECOME Selected.
 *
 * ── ⚠ ONE DELIBERATE EXTENSION OF THE WRITTEN RULE: REPARENTING ─────────────────────────────
 * A row that is ALREADY Selected and whose `Disposition__c` CHANGES arrives Selected on a
 * disposition it was not previously Selected on. Its status never "changed to Selected", so the
 * rule as literally written would let it create the second Selected row this class exists to
 * prevent. The condition below is therefore "NEWLY SELECTED **ON THIS DISPOSITION**" — a strict
 * superset that leaves all three consequences above intact (no service reparents; an unrelated save
 * on an already-Selected row does not change its parent; a reduction still makes nothing become
 * Selected). `reparentingASelectedRowOntoAnOccupiedDisposition_isRejected` pins it. If a reviewer
 * wants the narrower literal rule, delete the `prior.Disposition__c != ...` clause and that one
 * test — nothing else depends on it.
 *
 * ── BUDGET / BULK ───────────────────────────────────────────────────────────────────────────
 * **AT MOST 1 SOQL AND EXACTLY 0 DML PER CHUNK — CONSTANT IN THE NUMBER OF SUBMISSIONS.** No SOQL
 * and no DML inside any loop; the one query is keyed on the `Set<Id>` of parent dispositions drawn
 * from the rows that are becoming Selected.
 *
 * 🔴 ZERO-QUERY FAST PATH. A chunk in which NO row is being inserted-as or changed-to Selected
 * returns BEFORE the query. That is what keeps this guard invisible to the 251-record bulk tests of
 * every unrelated feature — the same "an ordinary save costs nothing" contract
 * `BovSubmissionBrokerStampService` already carries on these very contexts.
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
 * @see force-app/main/default/classes/BovSubmissionService.cls (the authored self-heal, and why this
 *      class must not copy it)
 * @see force-app/main/default/classes/DispositionOfferSelectionGuardService.cls (the twin)
 */
public with sharing class BovSubmissionSelectionGuardService {

    /**
     * The `Submission_Status__c` value marking the appointed broker. `Submission_Status__c` is
     * RESTRICTED to exactly {Backup, Selected}, so this is half the value set. Each layer holds its
     * own copy (`BovSubmissionService`, `BovSubmissionTriggerHandler`, `BovSubmissionSelector`);
     * this one is the guard's.
     */
    @TestVisible
    private static final String STATUS_SELECTED = 'Selected';

    /**
     * The refusal, surfaced verbatim to whoever attempted the save — a user in the UI, a row error
     * in the Bulk API, an exception in anonymous Apex.
     *
     * 🔴 IT NAMES BOTH REMEDIES, WHICH IS WHAT MAKES IT ACTIONABLE. "Only one may be Selected" alone
     * would tell a user they are wrong without telling them what to do; the whole reason this is a
     * refusal rather than a self-heal is that a HUMAN must decide which broker is appointed.
     */
    @TestVisible
    private static final String DUPLICATE_SELECTED_MESSAGE =
        'This disposition already has a Selected broker response, and only one is allowed. '
        + 'Use the Replace Broker action on the Disposition, or set the current Selected response '
        + 'to Backup in the same save.';

    /**
     * Refuses any save that would leave a Disposition with more than one Selected submission.
     * Mutates nothing and performs no DML — it either returns silently or calls `addError` on the
     * offending rows.
     *
     * @param incoming Trigger.new. Null/empty-safe.
     * @param oldMap   Trigger.oldMap on update; NULL ON INSERT — on insert every Selected row counts
     *                 as newly Selected, which is the correct reading.
     * @example
     * BovSubmissionSelectionGuardService.enforceSingleSelected(newList, oldMap);
     */
    public static void enforceSingleSelected(
        List<BOV_Submission__c> incoming,
        Map<Id, BOV_Submission__c> oldMap
    ) {
        if (incoming == null || incoming.isEmpty()) {
            return;
        }

        // ── PASS 1 — classify, entirely in memory. ────────────────────────────────────────────
        // `becomingSelected`  the rows to JUDGE.
        // `selectedByParent`  how many incoming rows will END Selected per disposition — this is
        //                     the "after applying every incoming row's new value" half.
        // `incomingIds`       EVERY incoming row's Id, including rows being demoted: the database
        //                     still reports them Selected, and their in-memory value must win.
        List<BOV_Submission__c> becomingSelected = new List<BOV_Submission__c>();
        Set<Id> parentIds = new Set<Id>();
        Map<Id, Integer> selectedByParent = new Map<Id, Integer>();
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
            Integer running = selectedByParent.get(submission.Disposition__c);
            selectedByParent.put(submission.Disposition__c, running == null ? 1 : running + 1);

            BOV_Submission__c prior = (oldMap == null || submission.Id == null)
                ? null
                : oldMap.get(submission.Id);
            // "Newly Selected ON THIS DISPOSITION" — see the REPARENTING note in the class header
            // for why the parent comparison is part of the test rather than only the status.
            Boolean wasAlreadySelectedHere = prior != null
                && STATUS_SELECTED.equals(prior.Submission_Status__c)
                && prior.Disposition__c == submission.Disposition__c;
            if (!wasAlreadySelectedHere) {
                becomingSelected.add(submission);
                parentIds.add(submission.Disposition__c);
            }
        }

        if (becomingSelected.isEmpty()) {
            // 🔴 THE ZERO-QUERY FAST PATH, and the reason consequences 2 and 3 in the class header
            // hold: an ordinary save, and ANY save that only reduces the Selected count, stops here.
            return;
        }

        // ── PASS 2 — ONE query for the whole chunk, never one per record. ─────────────────────
        // Rows present in this chunk are SKIPPED: the database reports their committed value, and
        // the in-memory value already counted in PASS 1 supersedes it. This single line is what
        // lets `replaceSelectedBroker`'s demote-and-promote pass.
        Map<Id, Integer> committedByParent = new Map<Id, Integer>();
        for (BOV_Submission__c sibling
                : BovSubmissionSelector.selectSelectedByDispositionIds(parentIds)) {
            if (incomingIds.contains(sibling.Id)) {
                continue;
            }
            Integer running = committedByParent.get(sibling.Disposition__c);
            committedByParent.put(sibling.Disposition__c, running == null ? 1 : running + 1);
        }

        // ── PASS 3 — judge. In-memory only; `addError` is not a write. ────────────────────────
        for (BOV_Submission__c submission : becomingSelected) {
            Integer committed = committedByParent.get(submission.Disposition__c);
            Integer incomingSelected = selectedByParent.get(submission.Disposition__c);
            // `- 1` excludes the row being judged, which PASS 1 counted in `selectedByParent`.
            Integer others = (committed == null ? 0 : committed) + incomingSelected - 1;
            if (others > 0) {
                // FIELD-LEVEL, naming the field the user must change. The platform bubbles a field
                // error to the page-level error area when the field is not on the layout, and
                // returns it as the row's error in the Bulk API — so nothing is lost on the
                // API-only paths this guard mainly exists for.
                submission.Submission_Status__c.addError(DUPLICATE_SELECTED_MESSAGE);
            }
        }
    }
}
