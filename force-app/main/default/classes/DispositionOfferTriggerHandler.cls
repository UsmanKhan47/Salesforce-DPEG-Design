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
 * ⚠ RE-COUNTED 2026-08-31 (Tranche 1 item 7, the disposition counters). "THIS handler now has
 * THREE contexts" is retracted in place for the same reason the sentence above it was: it is a
 * COUNT, and this is the second time this file's count has decayed. There are now SIX — `after
 * insert`, `after delete` and `after undelete` were added, and all three exist for ONE job, the
 * `Offers_Received__c` recompute. 🔴 DO NOT TRUST THIS NUMBER EITHER; read the overrides.
 *
 *   before insert -> 🔴 NEW 2026-08-20. The single-selected guard, and (later the same day,
 *                    Workstream D) the buyer-name stamp. `stampAcceptedStatus` is deliberately NOT
 *                    called: an insert cannot be an approval TRANSITION (`Approval_Status__c` cannot
 *                    have changed on a row that did not exist), so it has nothing to detect here.
 *                    ⚠ The buyer stamp IS called, and that asymmetry is argued at the method — it
 *                    derives a field from a VALUE, not from a transition. See the trigger file's
 *                    header for the blast-radius argument.
 *   before update -> `Offer_Status__c = 'Accepted'` on the offer itself (in memory, ZERO DML), the
 *                    single-selected guard, and the buyer-name stamp.
 *   after update  -> the PARENT Disposition: stage `Offer Selection` -> `LOI` (guarded), and
 *                    `Accepted_Offer_Price__c` stamped from `Offer_Amount__c` (unguarded)
 *                    ⚠ PLUS, since 2026-08-31, the `Offers_Received__c` recompute — but ONLY for
 *                    a REPARENT. An offer whose `Disposition__c` moved must decrement the sale it
 *                    left as well as increment the one it joined, and an update context is the
 *                    only place both Ids exist. Any other update returns at zero query and zero
 *                    DML cost.
 *
 *   after insert  -> 🔴 NEW 2026-08-31. `Offers_Received__c` recompute, nothing else. Before this
 *   after delete     change this object had NO after-insert, after-delete or after-undelete
 *   after undelete   context at all — an offer could be created, withdrawn or restored with
 *                    nothing to notice it. All three exist for the one counter, they all route to
 *                    `DispositionCounterRollupService`, and each RECOMPUTES from an aggregate
 *                    rather than incrementing (a counter that cannot self-heal is a counter that
 *                    is silently wrong forever). `after delete` reads `Trigger.old`, the only
 *                    place the parent Id still exists.
 *
 * 🔴 BLAST RADIUS OF THE 2026-08-31 EXPANSION, STATED PLAINLY: this trigger now fires on EVERY
 * `Disposition_Offer__c` INSERT, DELETE AND UNDELETE IN THE ORG, and each costs ONE aggregate
 * query plus ONE `Database.update` PER CHUNK — never per record. The `after update` half costs
 * NOTHING unless a lookup moved. That is the honest price of a field the platform cannot roll up
 * (both child links are Lookups, so no roll-up summary is available), and it is asserted rather
 * than asserted-about in `DispositionCounterRollupServiceTest`'s 251-row budget tests.
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
 * 🔴 AMENDED 2026-08-21 (UAT DEFECT — `DISP-0011` / `OFFER-0007`). BOTH NUMBERED CLAIMS ABOVE ARE
 * STILL TRUE AND ARE RETAINED. What was FALSE was never written down: the IMPLICIT premise that a
 * lock is the only thing that can refuse this write. It is not. `Disposition__c` is OWD **Private**,
 * and this code runs as the APPROVER, who does not own the parent — the submitter does. Measured on
 * the live org: `UserRecordAccess` for the approver on `DISP-0011` returned
 * `HasReadAccess = true, HasEditAccess = false`. So the selector read SUCCEEDED (both disposition
 * permission sets carry `viewAllRecords = true`) and the `Database.update` was REFUSED for lack of
 * record-level EDIT, `allOrNone = false` swallowed it, and the offer read `Accepted` beside a parent
 * that never moved. Nothing was locked. See `advanceParents` for the fix and for why
 * `AccessLevel.SYSTEM_MODE` — which the original author reached for precisely to solve this — could
 * never have done so.
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
 * 🔴 CORRECTED IN PLACE 2026-08-21. THE PARAGRAPH ABOVE IS ACCURATE ABOUT `ENTITY_IS_LOCKED` AND IS
 * KEPT. IT IS WRONG BY OMISSION, AND THE OMISSION IS WHAT COST A UAT CYCLE: it names a lock as THE
 * cause of a silent residual on the very statement whose ACTUAL production failure was a SHARING
 * refusal (`INSUFFICIENT_ACCESS_OR_READONLY` on a record the approver may read and may not edit).
 * A reader trusting this paragraph would have checked `ProcessInstanceWorkitem`, found none, and
 * concluded the write must have succeeded. THE LOCK IS ONE OF (at least) THREE REFUSALS THIS
 * STATEMENT CAN TAKE — a lock, a validation rule, and record-level sharing — and until 2026-08-21
 * the third was neither handled nor written down. It is handled now (`ParentAdvanceWrites`, below);
 * the other two remain genuine, remain soft, and are the reason `allOrNone = false` stays.
 * ⚠ AND THE RESIDUAL IS NO LONGER UNINSPECTED. Every failure now reaches the debug log at ERROR and
 * `lastRunParentWriteFailures`. "Self-heals on the next save" is still true of the LOCK case and was
 * never true of the sharing case — that one recurred on every retry, by the same principal, forever.
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
 * ⚠ SHARING: the class is `with sharing` and stays that way. EXACTLY ONE statement escapes it — the
 * parent `Database.update`, in the `private without sharing ParentAdvanceWrites` inner class, whose
 * own declaration carries the full justification (ARCHITECTURE.md §2's prescribed shape). Read it
 * before touching either keyword; the escape is not inherited by anything else in this file.
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
 *                which returns before querying when no row is becoming selected + AT MOST ONE query
 *                and ZERO DML for the buyer-name stamp (2026-08-20, Workstream D), which likewise
 *                returns before querying when no row changed `Buyer__c`.
 * All CONSTANT in the number of offers. A chunk in which no offer became Approved-and-Selected,
 * none became selected and none changed its buyer costs nothing at all.
 * ⚠ THE BEFORE-CONTEXT WORST CASE IS THEREFORE **TWO** QUERIES PER CHUNK, NOT ONE. Both are
 * per-chunk constants, so the ceiling does not move with record count; the number is stated because
 * "AT MOST ONE query" was true of this context until Workstream D and a reader may be carrying it.
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
        // 🔴 THE BUYER-NAME STAMP **DOES** RUN ON INSERT, UNLIKE `stampAcceptedStatus` ABOVE, AND
        // THE DIFFERENCE IS NOT ARBITRARY. That method detects a TRANSITION (`Approval_Status__c`
        // CHANGING to 'Approved'), which is unreachable on a row that did not previously exist. This
        // one derives a field from a VALUE (`Buyer__c`), and an offer CREATED naming a buyer Contact
        // must carry its `Buyer_Name__c` from that very first save — otherwise the offer inserts with
        // a blank name and `Buyer_Required_On_Offer` refuses it. Same `null` old-map convention.
        DispositionOfferBuyerStampService.stampBuyerName(
            (List<Disposition_Offer__c>) newList,
            null
        );
    }

    /**
     * AFTER INSERT — 🔴 NEW 2026-08-31 (Tranche 1 item 7). The context did not exist before this
     * change; this is its only job.
     *
     * A new offer arriving is the primary event `Disposition__c.Offers_Received__c` exists to
     * track. It must be an AFTER context: the count is read back from the database by an aggregate,
     * so the rows have to be committed for the query to see them. A before-context recompute would
     * read the count from BEFORE this save and write a number that is always one chunk stale.
     *
     * ⚠ THE PARENT WRITE'S JUSTIFICATION IS NOT RESTATED HERE. It lives at
     * `DispositionCounterRollupService.ParentCounterWrites` — SYSTEM_MODE for FLS, a narrow
     * `private without sharing` inner class for record-level access, `allOrNone = false` so a
     * refused counter can never roll back the user's own offer save. Three separate decisions, one
     * home. ⚠ Note this handler's OWN `ParentAdvanceWrites` below is a DIFFERENT write with the
     * same shape; they are deliberately not merged (one is an approval outcome, one is a count).
     */
    protected override void afterInsert() {
        DispositionCounterRollupService.recalculateOffersForRows(
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
        DispositionOfferBuyerStampService.stampBuyerName(
            (List<Disposition_Offer__c>) newList,
            (Map<Id, Disposition_Offer__c>) oldMap
        );
    }

    protected override void afterUpdate() {
        advanceParents(
            (List<Disposition_Offer__c>) newList,
            (Map<Id, Disposition_Offer__c>) oldMap
        );
        // 🔴 ADDED 2026-08-31 (Tranche 1 item 7). It is here for the REPARENT and nothing else: an
        // offer whose `Disposition__c` moved leaves the old sale one too high and the new one too
        // low, and only an update context can see both sides. Every other kind of update — a
        // status change, an amount edit, the approval stamp two lines above — leaves the lookup
        // alone and returns from the service after ONE in-memory pass, before any SOQL and any
        // DML. That zero-cost fast path is why this line does not move
        // `BovSubmissionTriggerHandlerTest`-style budget assertions on ordinary offer saves, and
        // why `DispositionApprovalService.selectOffer`'s 251-row exclusivity sweep still costs the
        // same as it did.
        DispositionCounterRollupService.recalculateOffersForRows(
            (List<Disposition_Offer__c>) newList,
            (Map<Id, Disposition_Offer__c>) oldMap
        );
    }

    /**
     * AFTER DELETE — 🔴 NEW 2026-08-31 (Tranche 1 item 7). The context did not exist before.
     *
     * ⚠ IT READS `Trigger.old`, WHICH IS THE ONLY PLACE THE PARENT ID STILL EXISTS. The rows are
     * gone from the database by the time the aggregate runs, which is exactly what makes the
     * recount correct — the deleted offer cannot be counted.
     *
     * 🔴 THIS IS THE HALF AN INCREMENTING COUNTER COULD NOT HAVE. Deleting the LAST offer on a
     * sale produces no `GROUP BY` row at all, so the recompute must default the miss to 0 rather
     * than skip it; `DispositionCounterRollupService.applyCounts` iterates the parent Id set for
     * precisely that reason. Without this context a withdrawn offer stays counted forever.
     *
     * ⚠ A DISPOSITION DELETE CASCADES HERE TOO. `Disposition_Offer__c.Disposition__c` is
     * `deleteConstraint SetNull`, so deleting a sale can put its own (now doomed) Id in play. The
     * parent write is `allOrNone = false` and the resulting `ENTITY_IS_DELETED` is logged rather
     * than thrown — see `DispositionCounterRollupService.recordFailures`, which names this case.
     */
    protected override void afterDelete() {
        DispositionCounterRollupService.recalculateOffersForRows(
            (List<Disposition_Offer__c>) oldList,
            null
        );
    }

    /**
     * AFTER UNDELETE — 🔴 NEW 2026-08-31 (Tranche 1 item 7). The context did not exist before.
     *
     * A restored offer must be counted again. `Trigger.new` carries the restored rows with their
     * lookups intact, so the recompute is identical to the insert case.
     *
     * ⚠ UNLIKE `BovSubmissionTrigger`, THIS OBJECT CARRIED NO RECORDED REFUSAL OF THE UNDELETE
     * CONTEXT — there was simply no after context at all here before today. Nothing is being
     * retracted on this side; the BOV side is a different story and is written up in
     * `BovSubmissionTrigger`'s header and `BovAutoSelectionService.reselectForDeleted`'s.
     * 🔴 CONSEQUENCE WORTH NAMING: `DispositionOfferSelectionGuardService` runs in BEFORE contexts
     * and the platform has no `before undelete`, so restoring an `Is_Selected__c = true` offer onto
     * a sale that has since selected another one produces two selected offers, unrefused. That
     * state is UNCHANGED by this method — the counter recomputes and says nothing about selection —
     * and it is deliberately left reachable, mirroring the BOV side's argument.
     */
    protected override void afterUndelete() {
        DispositionCounterRollupService.recalculateOffersForRows(
            (List<Disposition_Offer__c>) newList,
            null
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

        // ── THREE SEPARATE DECISIONS ON ONE STATEMENT. NONE COVERS ANOTHER'S OBSTACLE. ──
        // SYSTEM_MODE      lifts CRUD + FLS — the approver holds neither on `Disposition__c`.
        // without sharing  lifts RECORD-LEVEL access — see `ParentAdvanceWrites` below. This is the
        //                  2026-08-21 fix and it is the one the original author thought SYSTEM_MODE
        //                  was providing.
        // allOrNone=false  keeps a refusal from rolling back THE APPROVAL ITSELF.
        //
        // 🔴 THE RESIDUAL, NAMED AND NARROWED: a lock or a validation rule can still refuse a row,
        // leaving the offer reading Accepted while the disposition sits at `Offer Selection` with no
        // accepted price and no sell-side LOI. VISIBLE (both records are on the same page and
        // disagree) and recoverable by hand. ⚠ THE RESULTS ARE NOW INSPECTED — see
        // `recordParentWriteFailures`. There is still no recovery ACTION available inside an
        // after-update trigger, which is why nothing is rethrown; what changed is that the failure is
        // no longer invisible, because "invisible" is what turned this into a UAT defect.
        recordParentWriteFailures(
            new ParentAdvanceWrites().apply(parentUpdates),
            parentUpdates
        );
    }

    /**
     * Every parent-write failure from the most recent `advanceParents` call, as
     * `<dispositionId> -> <STATUS_CODE> | <message>`. Empty on a clean run and reset at the top of
     * every `recordParentWriteFailures` call, so it describes ONE trigger chunk and not a session.
     *
     * ⚠ IT EXISTS TO BE ASSERTED ON, not merely to be read. `DispositionOfferTriggerHandlerTest`'s
     * non-owner approver test asserts it is EMPTY — which is what makes that test fail loudly with
     * the actual `StatusCode` if the sharing escape below is ever removed, instead of failing with
     * an opaque "expected LOI, was Offer Selection".
     */
    @TestVisible
    private static List<String> lastRunParentWriteFailures = new List<String>();

    /**
     * Sends every refused row to the debug log at ERROR and to `lastRunParentWriteFailures`.
     *
     * 🔴 THIS IS THE HALF OF THE 2026-08-21 FIX THAT SURVIVES THE NEXT UNKNOWN CAUSE. The sharing
     * escape closes the cause we measured; this closes the CLASS of defect — a soft DML whose
     * `SaveResult` nobody looked at, which is how a refusal became a silent no-op that read exactly
     * like success from every surface a person can see. Shape copied deliberately from
     * `DealFolderService.stampAll`, which had already learned it.
     *
     * ⚠ NOTHING IS RETHROWN AND NOTHING IS RETRIED. Both would roll back the approval — see the
     * `allOrNone = false` argument at the call site — and this method must be incapable of doing
     * that. It is a report, not a recovery.
     *
     * @param results Parallel to `attempted`, in input order; never null (a `Database.update`
     *                always returns one result per row).
     * @param attempted The rows handed to the DML, used only for their Ids.
     */
    private void recordParentWriteFailures(
        List<Database.SaveResult> results,
        List<Disposition__c> attempted
    ) {
        lastRunParentWriteFailures = new List<String>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                continue;
            }
            List<Database.Error> errors = results[i].getErrors();
            String detail = errors.isEmpty()
                ? 'no error detail returned'
                : errors[0].getStatusCode() + ' | ' + errors[0].getMessage();
            lastRunParentWriteFailures.add(attempted[i].Id + ' -> ' + detail);
            // NOT debug output — this is the failure channel; see lastRunParentWriteFailures.
            // `allOrNone = false` means a refused parent write throws nothing, so removing this
            // line restores the silent no-op this handler exists to close. A lint pass will flag
            // it; leave it.
            System.debug(LoggingLevel.ERROR,
                'DispositionOfferTriggerHandler.advanceParents: LOST PARENT ADVANCE on '
                + 'Disposition__c ' + attempted[i].Id + ' -> ' + detail
                + ' | the offer is Accepted and its sale did NOT move to LOI or take an accepted '
                + 'price. Running user: ' + UserInfo.getUserId() + '.');
        }
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE ONE STATEMENT THAT ESCAPES SHARING, AND WHY IT HAS TO. ADDED 2026-08-21.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * WHO RUNS THIS CODE: the APPROVER of `Offer_Selection_Approval`. This handler's after-update
     * context is reached by that approval's own `finalApprovalActions` field update writing
     * `Approval_Status__c`, so the running user is whoever clicked Approve — never the analyst who
     * submitted, and never (in the DPEG model) the owner of the parent Disposition.
     *
     * WHY THEY PREDICTABLY LACK RECORD-LEVEL EDIT ON THE TARGET — three facts that compose:
     *   1. `Disposition__c` is OWD **Private** (`InternalSharingModel = Private`, measured via
     *      Tooling `EntityDefinition` 2026-08-21).
     *   2. The record is owned by the SUBMITTER. The only Edit-granting sharing rule on the object
     *      is `Disposition_Team_RW` (Acquisitions_Analyst + subordinates -> `DPEG_Acquisitions_Team`),
     *      which an approving Principal is outside of.
     *   3. `DPEG_Disposition_View` — the set the Principal persona actually carries — grants
     *      `viewAllRecords = true` and NO `modifyAllRecords`. That combination is the trap: the
     *      approver can READ every disposition and EDIT almost none, so the guard read above returns
     *      the row and the write is then refused. Measured on `DISP-0011`:
     *      `HasReadAccess = true, HasEditAccess = false`.
     *
     * 🔴 `AccessLevel.SYSTEM_MODE` WAS NOT SUFFICIENT AND COULD NEVER HAVE BEEN. This class's own
     * header attributed the SYSTEM_MODE argument to the approver being "read-only on
     * `Disposition__c`" — i.e. the author reached for it to solve EXACTLY this problem. Per
     * ARCHITECTURE.md §2: *"🔴 `SYSTEM_MODE` bypasses CRUD/FLS ONLY — it does NOT bypass sharing."*
     * SYSTEM_MODE removed the OBJECT-level refusal and left the RECORD-level one standing, which is
     * why the defect presented as a silent no-op rather than as a `TypeException` — the write got
     * far enough to produce a `SaveResult`, and nobody read it.
     *
     * WHY THE ESCAPE IS BOUNDED TO THIS ONE WRITE: this class stays `with sharing`, the selector
     * stays `with sharing`, and this inner class holds ONE statement against a list the CALLER
     * built. It cannot query, cannot choose rows, and cannot widen: every Id in `parentUpdates` came
     * back from a `with sharing` selector read, so a disposition the approver genuinely cannot SEE
     * is still never written. The escape converts "may read, may not edit" into "may write the two
     * fields this approval decides" and nothing else. ARCHITECTURE.md §2 prescribes exactly this
     * shape — *"a narrow `private without sharing` inner class holding only that query… never
     * `without sharing` on a whole selector"* — and the repo precedents are
     * `DispositionOfferSelector.TractionReads` (read) and `NdaExpiryAlertBatch.stampMarkers` (write).
     *
     * ⚠ DO NOT PROMOTE THIS TO THE OUTER CLASS. The before-context work
     * (`DispositionOfferSelectionGuardService`, `DispositionOfferBuyerStampService`) is deliberately
     * sharing-scoped and its own headers argue for that; `without sharing` on the handler would
     * silently re-authorise it.
     */
    private without sharing class ParentAdvanceWrites {
        /**
         * @param parentUpdates Disposition shells built by `advanceParents` from rows a
         *                      `with sharing` selector returned; never null, never empty.
         * @return One `Database.SaveResult` per row, in input order. The caller inspects them.
         */
        private List<Database.SaveResult> apply(List<Disposition__c> parentUpdates) {
            return Database.update(parentUpdates, false, AccessLevel.SYSTEM_MODE);
        }
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
