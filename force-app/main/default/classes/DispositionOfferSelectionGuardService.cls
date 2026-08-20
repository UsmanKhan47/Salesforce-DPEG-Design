/**
 * Enforces "AT MOST ONE `Is_Selected__c = true` offer per Disposition" as a BEFORE-CONTEXT TRIGGER
 * GUARD that REFUSES the offending save. Added 2026-08-20 with the disposition redesign, Tranche 2
 * Workstream A2 (`agent-output/disposition-tranche-2-requirements.md` §1.2, constraint solution 1).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ THIS IS THE LOWER-PRIORITY HALF OF A PAIR, AND SAYING SO IS PART OF THE FILE
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * It is NOT of equal value to `BovSubmissionSelectionGuardService`, and treating the two as
 * equivalent would misdescribe the risk. `Disposition_Offer__c.Is_Selected__c` is:
 *
 *   - written ONLY by `DispositionApprovalService.selectOffer`, which already clears every sibling
 *     in the SAME transaction, under a savepoint, in ONE bulk DML; and
 *   - READ-ONLY FLS IN BOTH permission sets — `DPEG_Disposition_Edit` lists it among the fields it
 *     deliberately keeps read-only.
 *
 * So the invariant is already unbreakable through the UI, through LDS, and through any `USER_MODE`
 * Apex. 🔴 THE RESIDUAL THIS CLASS CLOSES IS API / DATA-LOADER / ANONYMOUS-APEX / `SYSTEM_MODE`
 * WRITES ONLY. That residual is real — it is the same argument
 * `Disposition__c.Broker_Lookup_Is_Off_Market_Only` makes about a `visibilityRule` ("it constrains a
 * browser, not the API") — but it is narrower than the BOV case, where
 * `BOV_Submission__c.Submission_Status__c` is granted READ + EDIT and the invariant is therefore
 * breakable BY HAND today.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 EVERYTHING ELSE IS THE TWIN'S REASONING, AND IT IS NOT REPEATED IN FULL HERE
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * Read `BovSubmissionSelectionGuardService`'s header for the complete argument on:
 *   - why a VALIDATION RULE cannot do this (a VR sees only the saving record) and why a ROLL-UP
 *     SUMMARY is impossible (every child -> Disposition__c relationship is a LOOKUP);
 *   - why a maintained counter + VR (the `NDA_Count__c` shape) is only EVENTUALLY correct and
 *     therefore useless for an exclusivity invariant;
 *   - 🔴 why this REFUSES rather than SELF-HEALS. The short form, because it is the decision most
 *     likely to be re-litigated: a correct self-heal cannot be a one-field write, so the trigger
 *     would perform a consequential write with no actor and no audit trail — exactly the defect
 *     Workstream B exists to fix — and refusal is the only safe answer to a bulk load, which needs
 *     to be told WHICH rows are wrong.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE EVALUATION RULE, AND THE THREE CONSEQUENCES THAT ARE LOAD-BEARING
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * > Error ONLY on a record being INSERTED AS selected, or CHANGED TO selected, when — AFTER
 * > APPLYING EVERY INCOMING ROW'S NEW VALUE IN MEMORY — another selected sibling remains on the
 * > same Disposition.
 *
 * A before-trigger's SOQL reads COMMITTED data, so a de-selected incumbent still reads
 * `Is_Selected__c = true` in the database; the in-memory value of any row present in this chunk
 * therefore SUPERSEDES its database row.
 *
 *   1. 🔴 `DispositionApprovalService.selectOffer` MUST STILL SUCCEED, AND IT DOES — STRUCTURALLY.
 *      It builds a CHANGE-ONLY list (the incumbent to `false`, the winner to `true`) and applies it
 *      in ONE `Database.update(flagUpdates, true, AccessLevel.SYSTEM_MODE)`. A before-update context
 *      sees BOTH rows, so the winner finds no remaining selected sibling. If that method is ever
 *      split into two DML statements it WILL start being refused here — the correct alarm, not a
 *      regression to work around. `existingSelectOfferService_stillSucceeds` is the falsifier and
 *      must never be deleted.
 *      ⚠ ITS CHANGE-ONLY BUILD IS ALSO WHY A RE-PICK OF THE SAME OFFER IS FREE: nothing enters
 *      `flagUpdates`, no DML fires, this guard is never invoked at all.
 *
 *   2. A ROW ALREADY SELECTED, SAVED FOR AN UNRELATED REASON, IS NEVER BLOCKED — including the
 *      approval's own `Approval_Status__c` field update, which fires these very contexts on a row
 *      whose `Is_Selected__c` is already true. It is not BECOMING selected, so it is never
 *      evaluated and costs zero queries. Without this, a pre-existing double-selected pair would be
 *      permanently unsavable — FROZEN.
 *
 *   3. ANY SAVE THAT REDUCES THE SELECTED COUNT IS ALWAYS PERMITTED. That is the remedy path out of
 *      a bad state; a guard that blocks the remedy is worse than no guard.
 *
 * ── ⚠ ONE DELIBERATE EXTENSION OF THE WRITTEN RULE: REPARENTING ─────────────────────────────
 * A row already selected whose `Disposition__c` CHANGES arrives selected on a disposition it was
 * not previously selected on, without its flag ever "changing to true". The condition below is
 * therefore "NEWLY SELECTED **ON THIS DISPOSITION**" — a strict superset that leaves all three
 * consequences above intact. Identical extension, identical reasoning, in the BOV twin.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THIS CLASS IS WHY `DispositionOfferTrigger` GAINED `before insert` ON 2026-08-20
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * The trigger declared `(before update, after update)` and NOTHING fired on insert, so an
 * insert-as-selected — the single most likely shape of the API/data-loader residual this class
 * exists for — would have walked straight past a before-update-only guard. The context list was
 * expanded and the trigger's header corrected in place. That expansion means this trigger now fires
 * on EVERY `Disposition_Offer__c` insert in the org, which is safe ONLY because of the zero-query
 * fast path below.
 *
 * ── BUDGET / BULK ───────────────────────────────────────────────────────────────────────────
 * **AT MOST 1 SOQL AND EXACTLY 0 DML PER CHUNK — CONSTANT IN THE NUMBER OF OFFERS.** No SOQL and no
 * DML inside any loop. 🔴 ZERO-QUERY FAST PATH when no incoming row is becoming selected — the
 * overwhelmingly common case, and what keeps this guard invisible to every unrelated bulk test.
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate APPLIES IN FULL; there is no exemption to
 * claim on a trigger path that loops over a collection.
 *
 * ── LAYERING / SHARING / MODE ───────────────────────────────────────────────────────────────
 * Service (`layer=service`). It cannot be a Domain method — the decision needs a SIBLING READ and
 * Domain classes carry zero SOQL. ZERO inline SOQL: the read goes to
 * `DispositionOfferSelector.selectSelectedByDispositionIds`, `WITH SYSTEM_MODE`, justified at that
 * method (`USER_MODE` THROWS rather than degrades, and inside a before-trigger that throw escapes as
 * `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY`, rolling back the user's own save — and `Is_Selected__c` is
 * read-only on both permission sets, so this is not a hypothetical).
 * `with sharing`, and NO `without sharing` inner class: the rows hang off a disposition the running
 * user is currently editing, which is not the `TractionReads` shape (an aggregate feeding an
 * automated verdict nobody checks).
 * ⚠ THE RESIDUAL, NAMED: a sharing-filtered read that MISSES a selected sibling INVERTS this guard
 * into a PERMITTER — it fails open. Bounded by `viewAllRecords = true` on `Disposition_Offer__c` in
 * both disposition permission sets, and by this being defence in depth behind an authored service.
 *
 * @see force-app/main/default/classes/BovSubmissionSelectionGuardService.cls (the twin — READ IT
 *      FIRST; the full argument lives there)
 * @see force-app/main/default/classes/DispositionOfferTriggerHandler.cls (the only caller)
 * @see force-app/main/default/classes/DispositionApprovalService.cls (the authored exclusivity write)
 */
public with sharing class DispositionOfferSelectionGuardService {

    /**
     * The refusal, surfaced verbatim to whoever attempted the save.
     *
     * ⚠ IT NAMES THE ACTION RATHER THAN THE FIELD. `Is_Selected__c` is read-only in both permission
     * sets and is not on any layout, so telling a user to "uncheck the other offer" would name a
     * remedy they cannot perform. `Select Offer` — which clears the previous selection in the same
     * save — is the only supported way to change the answer.
     */
    @TestVisible
    private static final String DUPLICATE_SELECTED_MESSAGE =
        'This disposition already has a selected offer, and only one is allowed. '
        + 'Use the Select Offer action on the Disposition, which clears the previous selection in '
        + 'the same save.';

    /**
     * Refuses any save that would leave a Disposition with more than one selected offer. Mutates
     * nothing and performs no DML — it either returns silently or calls `addError` on the offending
     * rows.
     *
     * @param incoming Trigger.new. Null/empty-safe.
     * @param oldMap   Trigger.oldMap on update; NULL ON INSERT — on insert every selected row counts
     *                 as newly selected, which is the correct reading.
     * @example
     * DispositionOfferSelectionGuardService.enforceSingleSelected(newList, oldMap);
     */
    public static void enforceSingleSelected(
        List<Disposition_Offer__c> incoming,
        Map<Id, Disposition_Offer__c> oldMap
    ) {
        if (incoming == null || incoming.isEmpty()) {
            return;
        }

        // ── PASS 1 — classify, entirely in memory. See the twin's header for the shape. ───────
        List<Disposition_Offer__c> becomingSelected = new List<Disposition_Offer__c>();
        Set<Id> parentIds = new Set<Id>();
        Map<Id, Integer> selectedByParent = new Map<Id, Integer>();
        Set<Id> incomingIds = new Set<Id>();

        for (Disposition_Offer__c offer : incoming) {
            if (offer.Id != null) {
                // EVERY incoming row, including rows being DE-selected: the database still reports
                // them selected and their in-memory value must win.
                incomingIds.add(offer.Id);
            }
            // An offer with no parent has no siblings, so there is no invariant to enforce.
            if (offer.Disposition__c == null) {
                continue;
            }
            // `!= true` rather than `== false`: an unset checkbox is NULL on an in-memory row, and
            // `true == null` is false in Apex — the same idiom `DispositionOfferTriggerHandler
            // .isApprovedSelection` uses on this field.
            if (offer.Is_Selected__c != true) {
                continue;
            }
            Integer running = selectedByParent.get(offer.Disposition__c);
            selectedByParent.put(offer.Disposition__c, running == null ? 1 : running + 1);

            Disposition_Offer__c prior = (oldMap == null || offer.Id == null)
                ? null
                : oldMap.get(offer.Id);
            Boolean wasAlreadySelectedHere = prior != null
                && prior.Is_Selected__c == true
                && prior.Disposition__c == offer.Disposition__c;
            if (!wasAlreadySelectedHere) {
                becomingSelected.add(offer);
                parentIds.add(offer.Disposition__c);
            }
        }

        if (becomingSelected.isEmpty()) {
            // 🔴 THE ZERO-QUERY FAST PATH. It carries consequences 2 and 3 in the class header, AND
            // it is what makes the new `before insert` context safe to add to a trigger that now
            // fires on every Disposition_Offer__c insert in the org.
            return;
        }

        // ── PASS 2 — ONE query for the whole chunk, never one per record. ─────────────────────
        Map<Id, Integer> committedByParent = new Map<Id, Integer>();
        for (Disposition_Offer__c sibling
                : DispositionOfferSelector.selectSelectedByDispositionIds(parentIds)) {
            if (incomingIds.contains(sibling.Id)) {
                continue; // the in-memory value already counted in PASS 1 supersedes it
            }
            Integer running = committedByParent.get(sibling.Disposition__c);
            committedByParent.put(sibling.Disposition__c, running == null ? 1 : running + 1);
        }

        // ── PASS 3 — judge. In-memory only; `addError` is not a write. ────────────────────────
        for (Disposition_Offer__c offer : becomingSelected) {
            Integer committed = committedByParent.get(offer.Disposition__c);
            Integer incomingSelected = selectedByParent.get(offer.Disposition__c);
            // `- 1` excludes the row being judged, which PASS 1 counted in `selectedByParent`.
            Integer others = (committed == null ? 0 : committed) + incomingSelected - 1;
            if (others > 0) {
                // RECORD-LEVEL, not field-level, and that is the one place this class deliberately
                // differs from its twin. `Is_Selected__c` is read-only FLS on both permission sets
                // and appears on no layout, so a field error would point at something the user can
                // neither see nor change. The Bulk API and anonymous Apex — the paths this guard
                // actually exists for — receive a record-level error identically either way.
                offer.addError(DUPLICATE_SELECTED_MESSAGE);
            }
        }
    }
}
