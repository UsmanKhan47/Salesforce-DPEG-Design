/**
 * Keeps `Disposition_Offer__c.Buyer_Name__c` (stored Text(255), label "Buyer") in agreement with
 * `Disposition_Offer__c.Buyer__c` (Lookup to Contact, DELIBERATELY UNFILTERED) — added 2026-08-20
 * with the buyer activity timeline (`agent-output/disposition-tranche-2-requirements.md` §3, D6.1 /
 * D6.2).
 *
 * The analyst now PICKS a buyer Contact instead of typing a name. `Buyer_Name__c` SURVIVES UNCHANGED
 * IN THE SCHEMA and keeps being populated — only the WRITER changes, from a human to this stamp.
 * That is what lets every existing consumer keep working with zero code change: the offer layouts
 * and the `dispositionOffer` LDS related list, and `DispositionBuyerTimelineService`, which reads it
 * as the LEGACY FALLBACK for rows created before `Buyer__c` existed (no backfill is in scope).
 *
 * ⚠ `objects/Disposition_Offer__c/fields/Buyer__c.field-meta.xml` says, of the schema-only half:
 * *"`Buyer_Name__c` IS NOT RETIRED OR REPOINTED BY THIS FIELD ... wiring a stamp between the two is
 * out of scope HERE ... and is a decision for whoever next touches this object's Apex."* **This
 * class is that decision.** The field is not retired; it becomes DERIVED. The comment is accurate
 * about its own change and is not contradicted by this one.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THIS COPIES `BovSubmissionBrokerStampService`'S **SKELETON**, NOT ITS BODY (design D6.2).
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `DispositionBrokerStampService` composes ONE field out of TWO parts (`Name + ' - ' + Firm`) via
 * `composeLabel()` with a 244-character proof. THIS service copies ONE field STRAIGHT ACROSS,
 * therefore: NO `SEPARATOR`, NO `composeLabel()`, and NO combined-length arithmetic. Shipping any of
 * them would be plausible-looking incorrect code — `Buyer_Name__c` would start reading
 * `Jane Doe - Acme Capital` where every existing row and every consumer expects a bare name.
 *
 * 🔴 AND THE CEILING IS **255 HERE AND 120 ON THE NDA TWIN** — the two are NOT the same number and
 * must not be shared through a constant. `Buyer_Name__c` is `Text(255)` (measured in the field
 * file); `Contact.Name` maxes at 121 characters (FirstName 40 + space + LastName 80). So the copy is
 * TRIVIALLY SAFE HERE AND NEEDS NO TRUNCATION, while `NdaBuyerStampService` genuinely needs one
 * because its target is `Text(120)`. A `left(255)` here would be exactly the dead code
 * `BovSubmissionBrokerStampService`'s header refuses to add, and the reason it refuses applies
 * verbatim: it silently starts mattering if someone widens `Contact.Name`, which is the wrong place
 * to discover it. ⚠ If `Buyer_Name__c` is ever NARROWED, re-do the arithmetic HERE.
 *
 * WHAT IS COPIED VERBATIM IN SUBSTANCE: the change-keyed detection, the two-pass
 * collect-then-assign structure, the one-query-per-chunk budget, the before-context lock argument,
 * the null-oldMap-on-insert handling, and the "no Contact resolved ⇒ leave the text unchanged"
 * branch.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 A THIRD DIVERGENCE FROM THE NDA TWIN, AND THE ONE THIS CLASS USED TO CLAIM DID NOT EXIST:
 *    **THE TWO DERIVED FIELDS DISAGREE ABOUT WHETHER A HUMAN MAY STILL TYPE INTO THEM.**
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * Recorded 2026-08-20 (code review W4). This header claims verbatim twinship with
 * `NdaBuyerStampService` on everything except the ceiling and the clear-branch. That was incomplete:
 * the two targets carry DIFFERENT FIELD-LEVEL SECURITY, which changes what a hand edit does.
 *
 * 🔴 MEASURED IN THE LIVE ORG (`usman-dpeg`, `FieldPermissions`, 2026-08-20) — not read off the
 * permission-set XML, because these fields are dual-module and the XML for one set does not answer
 * the question:
 *
 *   PERMISSION SET             NDA__c.Counterparty_Name__c   Disposition_Offer__c.Buyer_Name__c
 *   DPEG_Disposition_Edit      read only                     read + EDIT      <- the divergence
 *   DPEG_Disposition_View      read only                     read only
 *   DPEG_Acquisition_Edit      read + EDIT                   (no such object)
 *   DPEG_Acquisition_View      read only                     —
 *   DPEG_Principal_PSG         read only                     read only
 *   DPEG_Junior_Analyst_PSG    read + EDIT                   read + EDIT
 *
 * ✅ SO THE **EFFECTIVE** ACCESS OF EVERY ASSIGNED PERSONA IS IDENTICAL ON BOTH FIELDS, AND THE
 * DIVERGENCE IS INVISIBLE IN PRACTICE. `DPEG_Junior_Analyst_PSG` contains BOTH `DPEG_Disposition_Edit`
 * AND `DPEG_Acquisition_Edit` (verified via `PermissionSetGroupComponent`, same date), and a
 * permission-set GROUP grants the UNION — so the acquisition set's edit on `Counterparty_Name__c`
 * overrides the disposition set's read-only line, and the junior analyst can type into both. The
 * principal can type into neither. ⚠ DO NOT READ THE `DPEG_Disposition_Edit` ROW AS "the NDA stamp
 * is protected from hand edits and the offer stamp is not" — it is not protected for anyone who is
 * actually assigned.
 *
 * ── WHICH BEHAVIOUR IS INTENDED: **BOTH ARE HAND-EDITABLE FOR THE EDITING PERSONA, DELIBERATELY** ──
 * Neither stamp is a lock and neither was ever meant to be. Both are CHANGE-KEYED on the lookup, so
 * a hand edit made in a save that leaves `Buyer__c` alone survives permanently, on both objects, and
 * both suites assert exactly that as CORRECT (`updateNotTouchingBuyer_changesNothing` here,
 * `updateNotTouchingBuyer_changesNothingAndCostsZeroQueries` on the twin). The reasons are concrete
 * rather than permissive:
 *   1. 🔴 ON THIS OBJECT A TYPED REMEDY IS NEEDED FOR A REAL, EXISTING ROW SHAPE.
 *      `Buyer_Required_On_Offer` fires on `ISBLANK(Buyer_Name__c)` with NO ISNEW/ISCHANGED guard, so
 *      a LEGACY offer whose text is blank is refused on EVERY subsequent save — including an edit
 *      that touches only the amount or the dates. ⚠ Being precise, because the stronger version of
 *      this sentence is wrong and would get quoted: such a row CAN still be rescued by setting
 *      `Buyer__c`, since a before trigger runs before validation and this stamp fills the text in
 *      that same save. But that is the ONLY other remedy, and it forces someone to produce a buyer
 *      CONTACT for a party who may exist as nothing but a name on an old offer. Revoking edit on
 *      `Buyer_Name__c` would make creating that Contact mandatory before the row can be touched
 *      again.
 *   2. This class's own clear-branch argument (below) turns on "a user who cleared the lookup AND
 *      typed a replacement name in ONE edit". That user cannot exist without edit on the text.
 *   3. On the NDA twin the same editability serves the OTHER module: acquisition NDAs have no
 *      `Buyer__c` at all (the lookup is granted on neither acquisition set), so `Counterparty_Name__c`
 *      is a purely TYPED field there and always must be.
 *
 * ── THE ACCEPTED COST, STATED PLAINLY ─────────────────────────────────────────────────────
 * A junior analyst can type `Buyer_Name__c = 'Acme'` on an offer whose `Buyer__r.Name` is
 * 'Jane Doe', and the two disagree FOREVER — the stamp will not correct it until `Buyer__c` itself
 * next changes. That is the same rename blind spot documented below, reached by hand instead of by a
 * Contact edit, and it is bounded the same way:
 *   - the buyer TIMELINE is unaffected — `DispositionBuyerTimelineService.resolveName` prefers
 *     `Buyer__r.Name` and only falls back to typed text when the lookup is null;
 *   - the damage is confined to the offer layouts, the `dispositionOffer` related list and reports;
 *   - it self-heals on the next buyer change.
 * ⚠ IF THAT COST EVER BECOMES UNACCEPTABLE, THE FIX IS FLS, NOT CODE. Do not add a "restore the
 * stamped value" branch — it would re-blank a name typed in the same save and, on legacy rows, walk
 * straight into `Buyer_Required_On_Offer`. **FLS is object/permission-set metadata and was NOT
 * changed by this code-only deliverable**; this block records the divergence and the decision, it
 * does not implement one.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 CLEARING `Buyer__c` DOES **NOT** BLANK THE TEXT — AND HERE THERE IS A LIVE VALIDATION RULE
 *    MAKING THAT MORE THAN A JUDGEMENT CALL.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * The twin `NdaBuyerStampService` reaches the same conclusion from three general arguments (single
 * field, not a composed pair; the text pre-dates the lookup and is analyst-typed on legacy rows;
 * blanking would discard a name typed in the same save). All three apply here. THIS OBJECT ADDS A
 * FOURTH, CONCRETE ONE:
 *
 *   `objects/Disposition_Offer__c/validationRules/Buyer_Required_On_Offer` is ACTIVE and its formula
 *   is `ISBLANK(Buyer_Name__c)`, with no ISNEW/ISCHANGED guard.
 *
 * A stamp that nulled `Buyer_Name__c` on clear would therefore make "remove the buyer lookup" an
 * UN-PERFORMABLE operation — the save is refused by a rule pointing at a field the user did not
 * touch — and worse, a user who cleared the lookup AND typed a replacement name in ONE edit would
 * have their typed value overwritten with null by this service and then be refused by that rule.
 * Leaving the text alone keeps the rule satisfied and keeps the remedy available.
 *
 * ⚠ THAT VALIDATION RULE'S OWN XML COMMENT INSTRUCTS WORKSTREAM D TO RE-POINT IT AT `Buyer__c`
 * (*"WHEN D LANDS, AMEND THIS ONE FILE: the formula becomes ISBLANK(Buyer__c)"*). **That amendment
 * is NOT made by this change and is not owned by this class** — validation rules are object metadata
 * and this deliverable is code-only. It is reported as outstanding rather than silently done.
 * 🔴 IF AND WHEN THAT AMENDMENT LANDS, RE-READ THIS SECTION: the fourth argument above evaporates
 * (the rule would then require the lookup, which is exactly what the user is clearing), and the
 * clear-branch decision would rest on the twin's three general arguments alone. Those three are
 * still sufficient — but they should be re-read and re-affirmed, not assumed.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY BEFORE-CONTEXT, AND WHY THAT IS A LOCK ARGUMENT RATHER THAN A PREFERENCE
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `Offer_Selection_Approval` targets `Disposition_Offer__c` and declares
 * `recordEditability = AdminOnly`, so a POST-SAVE second DML against an offer whose own approval is
 * pending throws `ENTITY_IS_LOCKED` — and `AccessLevel.SYSTEM_MODE` does not lift a lock. A Queueable
 * does not fix it either: a pending approval outlives the job (review D20/W1). An IN-MEMORY
 * assignment inside the save the user was ALREADY permitted to make costs ZERO extra DML and no lock
 * can refuse it.
 * ⚠ THIS IS NOT HYPOTHETICAL ON THIS OBJECT. `DispositionOfferTriggerHandler` already writes
 * `Offer_Status__c` in the before context for precisely this reason, and its header argues it at
 * length. This stamp joins that context rather than inventing a second answer.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE WRITER TABLE — WHY THE EXPANDED BEFORE CONTEXTS CANNOT COLLIDE WITH ANY OTHER WRITER
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * The guard is STRUCTURAL: this stamp fires ONLY when `Buyer__c` CHANGES, and every other writer of
 * this object leaves `Buyer__c` untouched, so each one re-enters this method and is SKIPPED after
 * ONE in-memory pass with ZERO queries:
 *
 *   Offer_Selection_Approval finalApprovalActions   -> Approval_Status__c
 *   DispositionOfferTriggerHandler.stampAcceptedStatus -> Offer_Status__c
 *   DispositionApprovalService.selectOffer          -> Is_Selected__c (the exclusivity sweep)
 *   CounterOfferService / the counter-price actions -> the counter-price fields
 *   TestDataFactory.createDispositionOffers         -> Buyer_Name__c directly, never Buyer__c
 *   An analyst editing amount / dates / terms       -> never the buyer lookup
 *
 * ✅ THE `TestDataFactory` ROW IS WHY EVERY EXISTING OFFER TEST IN THE SUITE STAYS GREEN BY
 * CONSTRUCTION. The factory sets `Buyer_Name__c = 'Test Buyer ' + i` and leaves `Buyer__c` NULL, so
 * on insert `null == null` reads as "unchanged" and this stamp never overwrites the fixture. **Do
 * not change `TestDataFactory.createDispositionOffers`**; a test that needs a buyer sets `Buyer__c`
 * itself from `TestDataFactory.createContact(s)` — the lookup is UNFILTERED, so an ordinary Contact
 * is accepted and `createBrokerContact` is NOT required (which is the opposite of the BOV twin, and
 * is the single easiest thing to get wrong by copying that suite).
 *
 * ⚠ WHERE THEY WOULD COLLIDE, THIS SERVICE WINS, AND THAT IS CORRECT. A single save that both
 * changed `Buyer__c` AND hand-typed a buyer name ends with the stamp, because a before trigger sees
 * the final field values and overwrites.
 *
 * ⚠ THE RENAME BLIND SPOT (identical to every sibling stamp's code-review W5). Keyed on `Buyer__c`
 * CHANGING, so editing the same buyer Contact's own `FirstName` / `LastName` never fires this
 * trigger and leaves `Buyer_Name__c` stale until the next save that actually changes `Buyer__c`.
 * Named here so it is not rediscovered as a bug.
 *
 * ⚠ LEGACY ROWS ARE SKIPPED FOREVER, BY DESIGN. Existing offers carry a typed `Buyer_Name__c` and a
 * NULL `Buyer__c`; `null == null` is "unchanged", so they are never touched and the timeline's
 * fallback keeps rendering them.
 *
 * ── LAYERING / BUDGET / BULK ──────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2, `layer=service`). ZERO inline SOQL — the Contact read goes to
 * `ContactSelector.selectNamesByIds`, `WITH SYSTEM_MODE` for automation-path reasons argued at that
 * method. ZERO DML at any record count: this mutates `Trigger.new` in place and returns void.
 *
 * BUDGET: **AT MOST 1 SOQL AND EXACTLY 0 DML PER CHUNK — CONSTANT IN THE NUMBER OF OFFERS.** A chunk
 * in which no record changed `Buyer__c` costs ZERO queries. That CONSTANCY is what the bulk tests
 * assert.
 * ⚠ IT DOES NOT MOVE `DispositionOfferTriggerHandler`'S DOCUMENTED BUDGET FOR THE COMMON CASE: that
 * handler's before contexts already carry "AT MOST ONE query and ZERO DML" for the single-selected
 * guard, and this stamp adds AT MOST ONE MORE, only on saves that change the buyer.
 *
 * 🔴 `.claude/rules/bulk-test-rule.md`'s 251-RECORD MANDATE **APPLIES IN FULL AND THERE IS NO
 * EXEMPTION TO CLAIM.** Trigger path, loops over a collection.
 *
 * ── FLS ───────────────────────────────────────────────────────────────────────────────────
 * A before-trigger field assignment is an in-memory SObject mutation and is NOT FLS-checked, so a
 * persona without EDIT on `Buyer_Name__c` still gets the stamp. A missing grant makes the value
 * invisible to that persona; it does not disable the stamp.
 * ⚠ THE FLS THAT DOES BITE THIS FEATURE IS ON THE READ SIDE. `Buyer__c` must be granted in
 * `DPEG_Disposition_Edit` / `DPEG_Disposition_View` before anyone — System Administrator included —
 * can see or set the picker (verified present in both files, 2026-08-20).
 *
 * ── SHARING ───────────────────────────────────────────────────────────────────────────────
 * `with sharing`. `SYSTEM_MODE` on the selector read lifts CRUD/FLS and NEVER sharing, so a Contact
 * the running user cannot SEE is simply absent from the result and correctly falls into the "leave
 * the text unchanged" branch.
 *
 * @see force-app/main/default/classes/DispositionOfferTriggerHandler.cls (the only caller)
 * @see force-app/main/default/classes/ContactSelector.cls (the SYSTEM_MODE name read)
 * @see force-app/main/default/classes/NdaBuyerStampService.cls (the twin — same skeleton, DIFFERENT
 *      ceiling; do not share a constant between them)
 * @see force-app/main/default/objects/Disposition_Offer__c/validationRules/Buyer_Required_On_Offer.validationRule-meta.xml
 */
public with sharing class DispositionOfferBuyerStampService {

    /**
     * Stamps `Buyer_Name__c` from `Buyer__c` for every record whose `Buyer__c` CHANGED in this save.
     * Mutates `newOffers` in place; performs no DML.
     *
     * ── THE FOUR OUTCOMES, AND WHY EACH IS THE SAFE DIRECTION ─────────────────────────────
     *
     *   `Buyer__c` UNCHANGED        -> the record is skipped ENTIRELY. 🔴 THE BRANCH THAT PROTECTS
     *                                  EVERY OTHER WRITER and keeps every existing fixture green.
     *   `Buyer__c` CLEARED to null  -> `Buyer_Name__c` is LEFT UNCHANGED. 🔴 See the class header's
     *                                  four arguments, one of which is a LIVE validation rule.
     *   `Buyer__c` SET, Contact read -> `Buyer_Name__c = buyer.Name`. Straight copy, no truncation
     *                                  (255 ≥ 121 — see the class header).
     *   `Buyer__c` SET, NO Contact   -> `Buyer_Name__c` is left UNCHANGED. Blanking is the more
     *                                  destructive direction AND would trip
     *                                  `Buyer_Required_On_Offer`; a stale name beside a lookup the
     *                                  user can see is visible and self-healing.
     *
     * @param newOffers Trigger.new. Null/empty-safe.
     * @param oldMap    Trigger.oldMap on update; NULL ON INSERT — on insert every non-null `Buyer__c`
     *                  counts as a change, and a null one is skipped, so an ordinary insert that
     *                  names no buyer costs nothing.
     * @example
     * DispositionOfferBuyerStampService.stampBuyerName(newList, oldMap);
     */
    public static void stampBuyerName(
        List<Disposition_Offer__c> newOffers,
        Map<Id, Disposition_Offer__c> oldMap
    ) {
        if (newOffers == null || newOffers.isEmpty()) {
            return;
        }

        // PASS 1 — detect. One query for the whole chunk rather than one per record.
        List<Disposition_Offer__c> changed = new List<Disposition_Offer__c>();
        Set<Id> buyerIds = new Set<Id>();

        for (Disposition_Offer__c offer : newOffers) {
            // On insert oldMap is null and priorBuyer is null, so being CREATED with a buyer counts
            // as a change. The `Id == null` guard mirrors both sibling services.
            Disposition_Offer__c prior =
                (oldMap == null || offer.Id == null) ? null : oldMap.get(offer.Id);
            Id priorBuyer = (prior == null) ? null : prior.Buyer__c;
            if (offer.Buyer__c == priorBuyer) {
                continue;
            }
            // A CLEAR is detected as a change and then does nothing (ApexDoc outcome 2). Filtered
            // out HERE rather than in pass 2 so a chunk of pure clears still costs ZERO queries.
            if (offer.Buyer__c == null) {
                continue;
            }
            changed.add(offer);
            buyerIds.add(offer.Buyer__c);
        }

        if (changed.isEmpty()) {
            // The common case: zero queries, zero DML, zero writes.
            return;
        }

        // ONE query for the whole chunk — never one per record.
        Map<Id, Contact> buyerById = new Map<Id, Contact>(
            ContactSelector.selectNamesByIds(buyerIds)
        );

        // PASS 2 — assign. In-memory only.
        for (Disposition_Offer__c offer : changed) {
            Contact buyer = buyerById.get(offer.Buyer__c);
            // ⚠ Absent key = unreadable under sharing, or deleted between the pick and this save.
            // Both leave the Text field exactly as it was — ApexDoc outcome 4.
            if (buyer == null) {
                continue;
            }
            // NO TRUNCATION, DELIBERATELY. Text(255) vs a 121-character maximum Name. See the class
            // header before adding one.
            offer.Buyer_Name__c = buyer.Name;
        }
    }
}
