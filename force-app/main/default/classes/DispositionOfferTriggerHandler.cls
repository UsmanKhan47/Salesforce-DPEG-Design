/**
 * Trigger handler for Disposition_Offer__c. Added 2026-08-19 with the disposition flow redesign
 * (DEV-5). It is the sibling of `BovSubmissionTriggerHandler` — same child-approval shape, same
 * lock argument — with ONE extra wrinkle: this handler also writes a field on the record the
 * approval LOCKS, which is why it uses two contexts where the BOV one uses one.
 *
 * ⚠ CORRECTED 2026-08-20 (Tranche 2 Workstream A2). The sentence above said "two contexts where the
 * BOV one uses one". BOTH halves of that comparison have since moved — the BOV handler gained before
 * contexts on 2026-08-20, and THIS handler now has THREE contexts. Retracted in place rather than
 * deleted because what it was actually explaining — why the offer's own status is written in the
 * BEFORE context — is unchanged and is argued in full below.
 *
 *   before insert -> 🔴 NEW 2026-08-20. ONLY the single-selected guard. Nothing else: an insert
 *                    cannot be an approval TRANSITION (`Approval_Status__c` cannot have changed on
 *                    a row that did not exist), so `stampAcceptedStatus` has nothing to detect here
 *                    and is deliberately NOT called. See the trigger file's header for the
 *                    blast-radius argument.
 *   before update -> `Offer_Status__c = 'Accepted'` on the offer itself (in memory, ZERO DML), and
 *                    the single-selected guard.
 *   after update  -> the PARENT Disposition: stage `Offer Selection` -> `LOI` (guarded), and
 *                    `Accepted_Offer_Price__c` stamped from `Offer_Amount__c` (unguarded)
 *
 * The two approval-driven halves fire on the same detection: `Approval_Status__c` CHANGING to
 * 'Approved' on an offer whose `Is_Selected__c` is true. `Offer_Selection_Approval` runs on the
 * OFFER and its `finalApprovalActions` field update writes `Approval_Status__c`, which re-fires this
 * trigger. ⚠ THAT FIELD UPDATE IS ALSO A SAVE ON A ROW WHOSE `Is_Selected__c` IS ALREADY TRUE, and
 * the guard must not refuse it — it does not, because the row is not BECOMING selected. That is
 * consequence 2 in `DispositionOfferSelectionGuardService`'s header, and it is not academic here.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THE OFFER'S OWN STATUS IS WRITTEN IN THE **BEFORE** CONTEXT
 * ══════════════════════════════════════════════════════════════════════════════
 * The offer IS the record under approval. Writing `Offer_Status__c` from the AFTER context would be
 * a SECOND DML against it, in a transaction where the approval may still hold
 * `recordEditability = AdminOnly` — the ENTITY_IS_LOCKED shape that produced
 * `DispositionNdaStampQueueable`, and one `AccessLevel.SYSTEM_MODE` cannot rescue (SYSTEM_MODE
 * lifts CRUD and FLS and NEVER a lock). A before-context assignment rides the approval's own save,
 * which the platform is performing anyway, so there is no second statement to refuse.
 *
 * ⚠ IT IS ALSO ROBUST TO A CONFIGURATION THIS CLASS DOES NOT OWN. Whether
 * `Offer_Selection_Approval` ends up declaring `AdminOnly` or `UnlockedRecord`, and whether the
 * lock has released by the time the field update's own trigger pass runs, the before-context
 * assignment is correct either way — it does not depend on the answer. An after-context DML would
 * depend on it, silently, and would start failing the day the approval's editability changed.
 *
 * ⚠ AND IT SAVES A DML AND A TRIGGER PASS. The alternative writes the same value the platform is
 * already writing a neighbouring field on.
 *
 * 🔴 THE PARENT WRITE CANNOT MOVE TO THE BEFORE CONTEXT, AND THAT IS STRUCTURAL. It targets a
 * DIFFERENT record, so it is a DML no matter which context it sits in. Same distinction
 * `DispositionTriggerHandler`'s header draws between `Listing_Date__c` (movable) and
 * `Primary_NDA__c` (not).
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THE PARENT WRITE IS SYNCHRONOUS
 * ══════════════════════════════════════════════════════════════════════════════
 * Identical to `BovSubmissionTriggerHandler`'s argument and re-derived rather than inherited,
 * because the stage differs and a stale premise is exactly how this repo has been bitten before:
 *   1. THE LOCKED RECORD IS THE OFFER, NOT THE DISPOSITION. A parent of a locked record is not
 *      itself locked.
 *   2. NO DISPOSITION APPROVAL CAN BE PENDING AT `Offer Selection`. The three Disposition-target
 *      processes enter at `Disposition Readiness`, at `Broker Selection` + Off Market, and at
 *      `Closing` + wire-verified. None enters at `Offer Selection`.
 * ⇒ Synchronous is safe, and a Queueable would assert a hazard that is not present.
 *
 * 🔴 STEP 2 IS ABOUT `Offer Selection`, AND IT DOES NOT COVER THE PRICE WRITE. AMENDED 2026-08-19
 * (code review S-1). The stage write is guarded to parents still sitting on `Offer Selection`, so
 * for THAT write step 2 is the whole story. `Accepted_Offer_Price__c` is written UNCONDITIONALLY,
 * at whatever stage the parent has since reached — which is the point of leaving it unguarded (see
 * the next section) but also means it is reachable at stages where a Disposition approval CAN be
 * pending and the parent CAN be locked. The concrete case: a rejected offer parks the sale at
 * `Offer Selection`, a second offer is selected and approved, but by then the sale has walked on to
 * `Closing` and `Closing_Approval` is pending — `recordEditability = AdminOnly`, so the parent is
 * locked. `Broker_Selection_Approval` and `Sale_Decision_Approval` are AdminOnly too; they simply
 * enter at stages a sale cannot be at once an offer exists.
 *
 * ⚠ WHAT ACTUALLY HAPPENS THEN, STATED SO IT IS NOT DISCOVERED IN PRODUCTION: the parent's row in
 * `Database.update(parentUpdates, false, AccessLevel.SYSTEM_MODE)` fails with `ENTITY_IS_LOCKED`
 * (SYSTEM_MODE lifts CRUD and FLS and NEVER a lock), `allOrNone = false` keeps the approval and
 * every other parent in the chunk intact, and the results are not inspected — so THE PRICE IS
 * SILENTLY NOT STAMPED. It is not a lost approval and not a wrong value, it is a missing one, and
 * it self-heals the moment anyone saves the offer again after the approval resolves. That trade is
 * accepted deliberately: throwing would roll back the approval to protect a display field, and a
 * Queueable would not help either, because unlike the D-1 advance path THIS transaction is not the
 * one releasing the lock — it is the `DispositionNdaStampQueueable` case, where review D20/W1
 * established that a pending approval OUTLIVES the job.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * 🔴 THE CURRENT-STAGE GUARD, AND WHY THE PRICE STAMP IS NOT GUARDED
 * ══════════════════════════════════════════════════════════════════════════════
 * The stage moves ONLY IF the parent is still on `Offer Selection`. A REJECTED offer parks the
 * disposition at `Offer Selection` for a re-pick (design D-3), so a second offer can be selected
 * and approved later — and by then the first may have been approved too, or the sale may have
 * walked on to `PSA`. Without the guard a late approval would drag a sale backwards out of `LOI`
 * or `PSA`, destroying an LOI negotiation in progress. `Accepted_Offer_Price__c` IS written
 * unconditionally, for the same reason `Selected_Broker__c` is on the BOV twin: it must always name
 * the currently accepted offer, whereas the stage is a position that only moves forward.
 *
 * ⚠ AND IT STAYS UNGUARDED ON PURPOSE — REVIEWED AND KEPT 2026-08-19 (S-1). Stage-guarding the
 * price would trade a rare, self-healing MISSING value (the `ENTITY_IS_LOCKED` residual named
 * above) for a routine, permanent STALE one: every late approval on a sale that had already moved
 * on would leave the field naming an offer the business abandoned, on every path, lock or no lock.
 * A field whose whole job is to say "this is the offer we accepted" is worse wrong than blank.
 *
 * ⚠ THE `LOI` HOP HAS A SIDE EFFECT THIS HANDLER DOES NOT PERFORM AND MUST NOT DUPLICATE. Entering
 * `LOI` is what makes `DispositionStageEntryService` auto-create the sell-side `LOI__c` — the
 * parent update below re-fires `DispositionTrigger`, which does it. That service needed NO change
 * for this feature; adding an LOI insert here would produce two.
 *
 * ── LAYERING ────────────────────────────────────────────────────────────────
 * ⚠ Like its BOV sibling, this handler carries its own APPROVAL logic and DML rather than routing to
 * a service, and for the same stated reason: one detection loop, one bulk update, one object, no
 * cross-object orchestration to own. ZERO inline SOQL — the parent read goes to
 * `DispositionSelector.selectStagesByIds`. The moment that logic needs a second object or a
 * non-trigger caller, it moves to a service.
 * ⚠ THE SINGLE-SELECTED GUARD IS ALREADY ON THE OTHER SIDE OF THAT LINE, AND THAT IS CONSISTENT
 * RATHER THAN CONTRADICTORY. The precedent above is CONDITIONED on the logic having "ZERO inline
 * SOQL"; the guard needs a SIBLING READ, which `.claude/rules/apex-layering-rule.md` forbids in a
 * TriggerHandler and in a Domain alike. Hence `DispositionOfferSelectionGuardService` — a Service
 * calling a Selector, the only conforming home. Same split, same reasoning, as the BOV twin.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * Trigger-driven, so `.claude/rules/bulk-test-rule.md`'s 251-record mandate APPLIES. ⚠ THE BUDGET
 * BELOW WAS WRITTEN FOR THE APPROVAL PATH ALONE AND IS AMENDED 2026-08-20 RATHER THAN REPLACED —
 * each job's own budget is unchanged:
 *   afterUpdate  ONE selector query + ONE `Database.update` per chunk.
 *   before*      ZERO statements for the `Offer_Status__c` stamp (an in-memory assignment at any
 *                record count) + AT MOST ONE query and ZERO DML for the single-selected guard,
 *                which returns before querying when no row is becoming selected.
 * All CONSTANT in the number of offers. A chunk in which no offer became Approved-and-Selected and
 * none became selected costs nothing at all.
 *
 * @see force-app/main/default/classes/BovSubmissionTriggerHandler.cls (the sibling child approval)
 * @see force-app/main/default/classes/DispositionApprovalService.cls (what SELECTS the offer)
 * @see force-app/main/default/classes/DispositionStageEntryService.cls (what the LOI hop triggers)
 */
public with sharing class DispositionOfferTriggerHandler extends TriggerHandler {

    /** `Approval_Status__c` value written by `Offer_Selection_Approval`'s finalApprovalActions. */
    @TestVisible
    private static final String APPROVAL_APPROVED = 'Approved';

    /** The `Offer_Status__c` value an approved offer lands on. */
    @TestVisible
    private static final String OFFER_ACCEPTED = 'Accepted';

    /** The parent stage this handler advances OUT OF, and only out of. */
    @TestVisible
    private static final String STAGE_OFFER_SELECTION = 'Offer Selection';

    /** The parent stage it advances INTO — whose ENTRY auto-creates the sell-side LOI. */
    @TestVisible
    private static final String STAGE_LOI = 'LOI';

    /**
     * 🔴 NEW CONTEXT, 2026-08-20. The ONLY reason `DispositionOfferTrigger` gained `before insert`:
     * an insert-as-selected is the most likely shape of the API/data-loader residual the guard
     * exists to close, and it would have walked straight past a before-update-only guard.
     *
     * ⚠ `stampAcceptedStatus` IS DELIBERATELY NOT CALLED HERE. Its detection requires
     * `Approval_Status__c` to have CHANGED to 'Approved', which cannot happen on a row that did not
     * previously exist — the same argument `BovSubmissionTrigger`'s header makes for having no
     * `after insert`. Adding it would be dead code that looks like a rule.
     *
     * `oldMap` is passed as NULL rather than `this.oldMap`: the platform leaves `Trigger.oldMap`
     * null on insert, and the guard's contract documents null-on-insert as the shape it expects.
     */
    protected override void beforeInsert() {
        DispositionOfferSelectionGuardService.enforceSingleSelected(
            (List<Disposition_Offer__c>) newList,
            null
        );
    }

    /**
     * ⚠ THE GUARD MUST NOT REFUSE `DispositionApprovalService.selectOffer`'S OWN EXCLUSIVITY SWEEP,
     * AND IT DOES NOT — STRUCTURALLY. That method builds a CHANGE-ONLY list and applies it in ONE
     * `Database.update`, so this context sees the de-selected incumbent and the newly selected
     * winner together, and the incumbent's in-memory `false` supersedes its committed `true`.
     * Splitting it into two DML statements would start being refused here.
     */
    protected override void beforeUpdate() {
        stampAcceptedStatus(
            (List<Disposition_Offer__c>) newList,
            (Map<Id, Disposition_Offer__c>) oldMap
        );
        DispositionOfferSelectionGuardService.enforceSingleSelected(
            (List<Disposition_Offer__c>) newList,
            (Map<Id, Disposition_Offer__c>) oldMap
        );
    }

    protected override void afterUpdate() {
        advanceParents(
            (List<Disposition_Offer__c>) newList,
            (Map<Id, Disposition_Offer__c>) oldMap
        );
    }

    /**
     * BEFORE UPDATE. Marks a just-approved selected offer `Accepted`, in memory.
     *
     * ⚠ FILL-IF-DIFFERENT, NOT UNCONDITIONAL — cheap, and it keeps the assignment honest about
     * being a state change rather than a re-write.
     *
     * ⚠ FLS: a before-trigger field assignment is an in-memory SObject mutation and is NOT
     * FLS-checked, so a persona without EDIT on `Offer_Status__c` still gets the stamp. That is the
     * intended outcome and matches `DispositionStageEntryService.stampListingDates`: a missing FLS
     * grant makes the value invisible to that persona, it does not disable the rule.
     */
    private void stampAcceptedStatus(
        List<Disposition_Offer__c> offers,
        Map<Id, Disposition_Offer__c> priorById
    ) {
        for (Disposition_Offer__c offer : offers) {
            if (!isApprovedSelection(offer, priorById)) {
                continue;
            }
            if (!OFFER_ACCEPTED.equals(offer.Offer_Status__c)) {
                offer.Offer_Status__c = OFFER_ACCEPTED;
            }
        }
    }

    /**
     * AFTER UPDATE. Moves each parent to `LOI` (if it is still on `Offer Selection`) and stamps the
     * accepted price.
     *
     * ── LAST-WRITER-WINS ON A CONTRIVED CHUNK, STATED HONESTLY ──────────────
     * Two offers on the SAME disposition approved in one chunk leaves the last one's price. That
     * state is already broken upstream — `DispositionApprovalService.selectOffer` writes
     * `Is_Selected__c` EXCLUSIVELY in a single DML, so only one offer can be in the approval — and
     * no ordering choice here repairs it. Deterministic and moving on beats a partial write or a
     * throw that would roll back the approval.
     */
    private void advanceParents(
        List<Disposition_Offer__c> offers,
        Map<Id, Disposition_Offer__c> priorById
    ) {
        Map<Id, Decimal> priceByDisposition = new Map<Id, Decimal>();
        for (Disposition_Offer__c offer : offers) {
            if (offer.Disposition__c == null || !isApprovedSelection(offer, priorById)) {
                continue;
            }
            priceByDisposition.put(offer.Disposition__c, offer.Offer_Amount__c);
        }
        if (priceByDisposition.isEmpty()) {
            return;
        }

        // ONE query for the whole chunk — never one per record. It answers only the idempotency
        // question: is this parent still on Offer Selection?
        List<Disposition__c> parentUpdates = new List<Disposition__c>();
        for (Disposition__c parent
                : DispositionSelector.selectStagesByIds(priceByDisposition.keySet())) {
            Disposition__c stamp = new Disposition__c(
                Id = parent.Id,
                Accepted_Offer_Price__c = priceByDisposition.get(parent.Id)
            );
            if (STAGE_OFFER_SELECTION.equals(parent.Disposition_Stage__c)) {
                stamp.Disposition_Stage__c = STAGE_LOI;
            }
            parentUpdates.add(stamp);
        }
        if (parentUpdates.isEmpty()) {
            return;
        }

        // ── allOrNone = false + SYSTEM_MODE — the same trade, and the same residual, as the BOV
        // sibling. SYSTEM_MODE because this runs as the APPROVER (read-only on `Disposition__c`);
        // allOrNone = false because an all-or-none failure would roll back THE APPROVAL ITSELF to
        // protect a stage advance.
        //
        // 🔴 THE RESIDUAL, NAMED: the offer reads Accepted while the disposition still sits at
        // `Offer Selection` with no accepted price — and, because the `LOI` hop never happened, with
        // no sell-side LOI either. VISIBLE (both records are on the same page and disagree) and
        // recoverable by hand. Results are deliberately not inspected: there is no recovery action
        // available inside an after-update trigger.
        Database.update(parentUpdates, false, AccessLevel.SYSTEM_MODE);
    }

    /**
     * Whether this save is the moment an offer's approval completed while it was the selected one.
     *
     * ── 🔴 A TRANSITION *AND* A STATE, AND BOTH HALVES ARE NEEDED ────────────
     * `Approval_Status__c` must have CHANGED to 'Approved' — an unrelated later save on an
     * already-approved offer must not re-stamp the parent — AND `Is_Selected__c` must be true NOW.
     * The second test is not redundant with the approval's own entry criterion: nothing stops an
     * offer being de-selected between submission and approval (a re-pick after a rejection does
     * exactly that, clearing every other offer's flag in one DML), and accepting an offer the
     * business has since abandoned is the one outcome this handler must never produce.
     *
     * ⚠ Shared by BOTH contexts on purpose, so the before-context stamp and the after-context
     * parent write can never disagree about which offers qualify. Two copies of this test is how
     * an offer ends up `Accepted` with a parent that never moved.
     */
    private Boolean isApprovedSelection(
        Disposition_Offer__c offer,
        Map<Id, Disposition_Offer__c> priorById
    ) {
        if (offer.Is_Selected__c != true) {
            return false;
        }
        if (!APPROVAL_APPROVED.equals(offer.Approval_Status__c)) {
            return false;
        }
        Disposition_Offer__c prior = (priorById == null) ? null : priorById.get(offer.Id);
        return prior == null || !APPROVAL_APPROVED.equals(prior.Approval_Status__c);
    }
}
