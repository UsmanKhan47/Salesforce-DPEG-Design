/**
 * Keeps `NDA__c.Counterparty_Name__c` (stored Text(120)) in agreement with `NDA__c.Buyer__c`
 * (Lookup to Contact, DELIBERATELY UNFILTERED) — added 2026-08-20 with the buyer activity timeline
 * (`agent-output/disposition-tranche-2-requirements.md` §3, D6.1 / D6.2).
 *
 * The analyst now PICKS a buyer Contact instead of typing a name. `Counterparty_Name__c` SURVIVES
 * UNCHANGED IN THE SCHEMA and keeps being populated — only the WRITER changes, from a human to this
 * stamp. That is what lets every existing consumer keep working with zero code change:
 * `NdaSelector.ExpiryAlertReads.expiryAlertLocator` (which selects it for the acquisition expiry
 * reminder), `NdaExpiryService`'s reminder body, and the NDA layouts and related lists that render
 * it. `DispositionBuyerTimelineService` reads it as the LEGACY FALLBACK for rows created before
 * `Buyer__c` existed — there is no backfill and none is in scope (design D6.3, item 11).
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THIS COPIES `BovSubmissionBrokerStampService`'S **SKELETON**, NOT ITS BODY (design D6.2).
 *    THE DIFFERENCE IS NOT COSMETIC AND COPYING THE BODY WOULD SHIP INCORRECT CODE.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `DispositionBrokerStampService` composes ONE field out of TWO parts (`Name + ' - ' + Firm`), so it
 * owns a `SEPARATOR` constant, a `composeLabel()` helper and a 121 + 3 + 120 = 244 ≤ 255 length
 * proof. THIS service copies ONE field STRAIGHT ACROSS, therefore:
 *   - NO `SEPARATOR` constant. There is nothing to separate.
 *   - NO `composeLabel()`. `Counterparty_Name__c` IS `Contact.Name`.
 *   - 🔴 THE CEILING IS **120**, NOT 244 OR 255. `Counterparty_Name__c` is `Text(120)` (measured in
 *     objects/NDA__c/fields/Counterparty_Name__c.field-meta.xml — the BOV twin's two targets are
 *     Text(255), which is exactly why that twin needs no truncation and this one does).
 *     `Contact.Name` can reach 121 characters (FirstName 40 + space + LastName 80), so an untruncated
 *     copy would raise `STRING_TOO_LONG` — and because this runs in a BEFORE trigger, that is not a
 *     cosmetic defect: it is a HARD FAILURE OF THE USER'S OWN NDA SAVE. The truncation below is
 *     therefore live code with a reachable trigger, NOT the dead `left(255)` the BOV twin's header
 *     rightly refuses to add.
 *
 * WHAT IS COPIED VERBATIM IN SUBSTANCE: the change-keyed detection, the two-pass
 * collect-then-assign structure, the one-query-per-chunk budget, the before-context lock argument,
 * the null-oldMap-on-insert handling, and the "no Contact resolved ⇒ leave the text unchanged"
 * branch.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 ONE DELIBERATE DIVERGENCE FROM THE SKELETON: CLEARING `Buyer__c` DOES **NOT** BLANK THE TEXT.
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `BovSubmissionBrokerStampService`'s second outcome nulls BOTH Text fields when the lookup is
 * cleared. That is right THERE and wrong HERE, and the reason is a property of the field, not a
 * preference:
 *   1. THE BOV ARGUMENT DOES NOT EXIST HERE. It blanks because `Broker_Display__c` is a FORMULA OVER
 *      TWO fields, so leaving one behind renders "half a broker" — a person beside a firm they do
 *      not work at. There is ONE field here and no formula over it, so there is no hybrid to
 *      fabricate.
 *   2. `Counterparty_Name__c` PRE-DATES THIS LOOKUP AND IS STILL ANALYST-TYPED ON EVERY LEGACY ROW.
 *      Blanking on clear turns "I picked the wrong Contact, let me undo that" into permanent loss of
 *      a name a human typed, on a field the timeline's legacy fallback depends on.
 *   3. IT WOULD DISCARD A NAME TYPED IN THE SAME SAVE. A before trigger sees final values, so a user
 *      who clears `Buyer__c` AND types a replacement name in one edit would have the typed value
 *      overwritten with null by a service that is supposed to be helping them.
 * ⚠ THE ACCEPTED CONSEQUENCE, STATED SO IT IS NOT REDISCOVERED AS A BUG: an NDA whose `Buyer__c` was
 * cleared keeps displaying the last stamped name. That is indistinguishable from a legacy row, which
 * is a state this feature already renders correctly and deliberately — not a fabrication, because
 * the name is one that genuinely was the counterparty. The twin service
 * `DispositionOfferBuyerStampService` makes the SAME choice for its own (additional) reason; read
 * both, they are not one decision made twice.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY BEFORE-CONTEXT, AND WHY THAT IS A LOCK ARGUMENT RATHER THAN A PREFERENCE
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * No approval process targets `NDA__c` today (measured: approvalProcesses/ holds seven files, whose
 * entry objects are `BOV_Submission__c`, `Disposition_Offer__c`, `Disposition__c` ×3 and
 * `Opportunity` ×2). So there is no `recordEditability = AdminOnly` lock on this object RIGHT NOW —
 * and the before context is still the correct answer, for two reasons that do not depend on that
 * measurement:
 *   - AN IN-MEMORY ASSIGNMENT INSIDE THE SAVE THE USER WAS ALREADY PERMITTED TO MAKE COSTS ZERO
 *     EXTRA DML AND NOTHING CAN REFUSE IT. A post-save second `update` would cost one DML per chunk
 *     forever, and would start throwing `ENTITY_IS_LOCKED` the day anyone adds an NDA approval —
 *     silently, in a place nobody would look. `AccessLevel.SYSTEM_MODE` does not lift a lock and a
 *     Queueable does not help (a pending approval outlives the job — review D20/W1).
 *   - IT IS THE SHAPE EVERY SIBLING STAMP IN THIS REPO USES, for the same reason:
 *     `DispositionStageEntryService.stampListingDates`, `DispositionBrokerStampService` and
 *     `BovSubmissionBrokerStampService`.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY A SERVICE RATHER THAN LOGIC IN THE HANDLER
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * The stamp needs a CONTACT SOQL READ, and `.claude/rules/apex-layering-rule.md` prohibits SOQL in a
 * TriggerHandler and prohibits SOQL in a Domain alike. A Service calling a Selector is the only
 * conforming home — the same split, for the same reason, as `BovSubmissionBrokerStampService` and
 * `DispositionOfferSelectionGuardService`.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE WRITER TABLE — WHY THE NEW TRIGGER CANNOT COLLIDE WITH ANY EXISTING WRITER
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `NdaTrigger` is BRAND NEW and fires on EVERY `NDA__c` insert and update in the org, ACQUISITION
 * NDAs INCLUDED. The guard is STRUCTURAL, not a matter of timing: this stamp fires ONLY when
 * `Buyer__c` CHANGES, and every existing writer leaves `Buyer__c` untouched, so each one re-enters
 * this method and is SKIPPED after ONE in-memory pass with ZERO queries:
 *
 *   DispositionStageEntryService.openBuyerNdas  -> inserts with Disposition__c/Status__c/Party_Role__c
 *   DispositionStageEntryService (this tranche)  -> Materials_Released_Date__c only
 *   RecordStageAdvanceService.advance            -> Status__c only
 *   flows/NDA_Signed_Status_Sync (before-save)   -> NDA_Signed__c / Date_Signed__c
 *   NdaExpiryAlertBatch.MarkerWrites             -> the two NDA_Alert_* marker fields
 *   DispositionNdaStampQueueable                 -> writes the PARENT Disposition, not the NDA
 *   TestDataFactory.createNdas                   -> Counterparty_Name__c directly, never Buyer__c
 *   An analyst editing status / dates / method   -> never the buyer lookup
 *
 * ✅ THE `TestDataFactory` ROW IS WHY EVERY EXISTING NDA TEST IN THE SUITE STAYS GREEN BY
 * CONSTRUCTION, AND IT IS THE SINGLE MOST REASSURING MEASURED FACT AVAILABLE ABOUT THIS CHANGE. The
 * factory sets `Counterparty_Name__c = 'Test Counterparty ' + i` and leaves `Buyer__c` NULL, so on
 * insert `null == null` reads as "unchanged" and this stamp never overwrites the fixture. **Do not
 * change `TestDataFactory.createNdas`**; a test that needs a buyer sets `Buyer__c` itself from
 * `TestDataFactory.createContact(s)` — and unlike the broker lookups, `Buyer__c` is UNFILTERED, so
 * an ordinary Contact is accepted and `createBrokerContact` is NOT required.
 *
 * ⚠ WHERE THEY WOULD COLLIDE, THIS SERVICE WINS, AND THAT IS CORRECT. A single save that both
 * changed `Buyer__c` AND hand-typed a counterparty name ends with the stamp, because a before
 * trigger sees the final field values and overwrites. Stated so nobody has to re-derive it.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ `NDA__c` IS A DUAL-MODULE OBJECT AND NOTHING HERE CHANGES ACQUISITION BEHAVIOUR
 * ══════════════════════════════════════════════════════════════════════════════════════════
 * `NDA__c` serves Acquisitions (`Acquisition_NDA`) as well as Dispositions (`Disposition_NDA`).
 * `Buyer__c` carries no record-type restriction and is technically settable on an acquisition NDA,
 * but it is granted on NEITHER acquisition permission set, so it is FLS-invisible there and no
 * acquisition surface can set it. Every acquisition save therefore takes the zero-query skip branch.
 * This service is deliberately NOT record-type-scoped: keying on the FIELD CHANGE rather than on the
 * record type is what makes it correct during the Master-record-type migration window, and it is the
 * same argument `DispositionStageEntryService.NDA_STAGE` records for not adding a record-type filter
 * that a comment merely implied.
 *
 * ⚠ THE RENAME BLIND SPOT (identical to both sibling stamps' code-review W5). Keyed on `Buyer__c`
 * CHANGING, so editing the same buyer Contact's own `FirstName` / `LastName` never fires this
 * trigger at all (the NDA row was not touched) and leaves `Counterparty_Name__c` stale until the
 * next save that actually changes `Buyer__c`. No mitigation exists today; it is named here so it is
 * not rediscovered as a bug.
 *
 * ⚠ LEGACY ROWS ARE SKIPPED FOREVER, BY DESIGN. Existing NDAs carry a typed `Counterparty_Name__c`
 * and a NULL `Buyer__c`; `null == null` is "unchanged", so they are never touched and the timeline's
 * fallback keeps rendering them. **No backfill is in scope and none is needed.**
 *
 * ── LAYERING / BUDGET / BULK ──────────────────────────────────────────────────────────────
 * Service (ARCHITECTURE.md §2, `layer=service`). ZERO inline SOQL — the Contact read goes to
 * `ContactSelector.selectNamesByIds`, `WITH SYSTEM_MODE` for automation-path reasons argued at that
 * method. ZERO DML at any record count: this mutates `Trigger.new` in place and returns void.
 *
 * BUDGET: **AT MOST 1 SOQL AND EXACTLY 0 DML PER CHUNK — CONSTANT IN THE NUMBER OF NDAs.** A chunk
 * in which no record changed `Buyer__c` — the overwhelmingly common case, since this trigger fires
 * on EVERY `NDA__c` write in the org — costs ZERO queries. That CONSTANCY, not merely "251 rows
 * produced 251 stamps", is what the bulk tests assert.
 *
 * 🔴 `.claude/rules/bulk-test-rule.md`'s 251-RECORD MANDATE **APPLIES IN FULL AND THERE IS NO
 * EXEMPTION TO CLAIM.** This is a trigger path and it loops over a collection. The
 * per-transaction-singleton exemption does not apply, and neither does the
 * `.claude/rules/content-publication-rule.md` carve-out — no content object is involved.
 *
 * ── FLS ───────────────────────────────────────────────────────────────────────────────────
 * A before-trigger field assignment is an in-memory SObject mutation and is NOT FLS-checked, so a
 * persona without EDIT on `Counterparty_Name__c` still gets the stamp — the same outcome
 * `DispositionStageEntryService.stampListingDates` and `BovSubmissionBrokerStampService` record for
 * their own stamps. A missing grant makes the value invisible to that persona; it does not disable
 * the stamp.
 * ⚠ THE FLS THAT DOES BITE THIS FEATURE IS ON THE READ SIDE AND IS NOT HERE. `Buyer__c` must be
 * granted in `DPEG_Disposition_Edit` / `DPEG_Disposition_View` before anyone — System Administrator
 * included — can see or set the picker (verified present in both files, 2026-08-20). 🔴 IF SOMEONE
 * HITS `QueryException: No such column` AFTER DEPLOY, THE FIX IS A PERMISSION SET, EVERY TIME.
 *
 * ── SHARING ───────────────────────────────────────────────────────────────────────────────
 * `with sharing`. `SYSTEM_MODE` on the selector read lifts CRUD/FLS and NEVER sharing, so a Contact
 * the running user cannot SEE is simply absent from the result and correctly falls into the "leave
 * the text unchanged" branch. **Do not add a `without sharing` inner class for this.**
 *
 * ⚠ THE TWO DERIVED FIELDS DISAGREE ABOUT HAND-EDITABILITY, AND THE ARGUMENT IS NOT REPEATED HERE.
 * `DPEG_Disposition_Edit` grants read-only on `Counterparty_Name__c` and read+EDIT on the twin's
 * `Disposition_Offer__c.Buyer_Name__c` — but a permission-set GROUP grants the union, and
 * `DPEG_Junior_Analyst_PSG` also carries `DPEG_Acquisition_Edit`, which DOES grant edit here. So the
 * effective access of every assigned persona is the same on both fields, and this field stays
 * editable for the acquisition module, where it has no lookup to derive from and is purely typed.
 * The measurement, the table and the decision live in ONE place, in the twin's header (code review
 * W4, 2026-08-20) — read it there rather than maintaining two copies that can drift apart.
 *
 * @see force-app/main/default/classes/NdaTriggerHandler.cls (the only caller)
 * @see force-app/main/default/classes/ContactSelector.cls (the SYSTEM_MODE name read)
 * @see force-app/main/default/classes/DispositionOfferBuyerStampService.cls (the twin — same
 *      skeleton, different ceiling, same clear-branch decision reached for an extra reason)
 * @see force-app/main/default/classes/BovSubmissionBrokerStampService.cls (the skeleton source)
 */
public with sharing class NdaBuyerStampService {

    /**
     * Length of `NDA__c.Counterparty_Name__c` — `Text(120)`, read off the field file.
     *
     * 🔴 IT IS 120 AND NOT 244 OR 255, AND THE ARITHMETIC IS LIVE RATHER THAN DEFENSIVE.
     * `Contact.Name` is a compound field whose maximum is 121 characters (FirstName 40 + one space +
     * LastName 80), so a name one character over this ceiling is REACHABLE with ordinary data — no
     * unusual configuration required. Without the truncation below, that NDA save fails outright
     * with `STRING_TOO_LONG`.
     * ⚠ If `Counterparty_Name__c` is ever widened, re-do the arithmetic HERE rather than deleting
     * the truncation: it is the only place the two lengths are compared.
     */
    @TestVisible
    private static final Integer COUNTERPARTY_NAME_MAX = 120;

    /**
     * Stamps `Counterparty_Name__c` from `Buyer__c` for every record whose `Buyer__c` CHANGED in
     * this save. Mutates `newNdas` in place; performs no DML.
     *
     * ── THE FOUR OUTCOMES, AND WHY EACH IS THE SAFE DIRECTION ─────────────────────────────
     *
     *   `Buyer__c` UNCHANGED       -> the record is skipped ENTIRELY. `Counterparty_Name__c` is
     *                                 neither read nor written nor considered. 🔴 THIS IS THE BRANCH
     *                                 THAT PROTECTS EVERY OTHER WRITER (class header) and the reason
     *                                 every existing fixture stays green.
     *   `Buyer__c` CLEARED to null -> `Counterparty_Name__c` is LEFT UNCHANGED. 🔴 This is the one
     *                                 place this service deliberately diverges from
     *                                 `BovSubmissionBrokerStampService`; the three reasons are in
     *                                 the class header and must be argued against before changing.
     *   `Buyer__c` SET, Contact read -> `Counterparty_Name__c = buyer.Name`, TRUNCATED to 120.
     *   `Buyer__c` SET, NO Contact  -> `Counterparty_Name__c` is left UNCHANGED. Blanking is the more
     *                                 destructive direction, and a stale name beside a lookup the
     *                                 user can see is visible and self-healing — the next successful
     *                                 save re-stamps it.
     *
     * ⚠ "NO Contact" COVERS TWO REACHABLE CASES AND TREATS THEM IDENTICALLY ON PURPOSE: the row is
     * not visible to the running user under sharing, or it was deleted between the pick and this
     * save. Both mean "I cannot author a truthful value", and inventing a different behaviour per
     * case would be two ways to be wrong instead of one way to be inert.
     *
     * ⚠ NOTE THAT THE CLEAR AND NO-CONTACT BRANCHES NOW HAVE THE SAME EFFECT (leave it alone) BUT
     * NOT THE SAME REASON. They are kept as separate, separately-commented branches rather than
     * collapsed, because a future change to either must re-read its own argument.
     *
     * @param newNdas Trigger.new. Null/empty-safe.
     * @param oldMap  Trigger.oldMap on update; NULL ON INSERT — on insert every non-null `Buyer__c`
     *                counts as a change, and a null one is skipped, so an ordinary insert that names
     *                no buyer (which is every acquisition NDA and every auto-created disposition
     *                NDA) costs nothing.
     * @example
     * NdaBuyerStampService.stampBuyerName(newList, oldMap);
     */
    public static void stampBuyerName(List<NDA__c> newNdas, Map<Id, NDA__c> oldMap) {
        if (newNdas == null || newNdas.isEmpty()) {
            return;
        }

        // PASS 1 — detect. Collects the records to restamp and the Contacts to resolve, so the query
        // below is issued once for the whole chunk rather than once per record.
        List<NDA__c> changed = new List<NDA__c>();
        Set<Id> buyerIds = new Set<Id>();

        for (NDA__c nda : newNdas) {
            // On insert oldMap is null and priorBuyer is null, so being CREATED with a buyer counts
            // as a change. The `Id == null` guard mirrors both sibling services.
            NDA__c prior = (oldMap == null || nda.Id == null) ? null : oldMap.get(nda.Id);
            Id priorBuyer = (prior == null) ? null : prior.Buyer__c;
            if (nda.Buyer__c == priorBuyer) {
                continue;
            }
            // A CLEAR is detected as a change and then does nothing (see the ApexDoc's second
            // outcome). It is filtered out here rather than in pass 2 so that a chunk in which every
            // changed record merely cleared its buyer still costs ZERO queries.
            if (nda.Buyer__c == null) {
                continue;
            }
            changed.add(nda);
            buyerIds.add(nda.Buyer__c);
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
        for (NDA__c nda : changed) {
            Contact buyer = buyerById.get(nda.Buyer__c);
            // ⚠ An absent key means the Contact is unreadable under sharing or was deleted. Both
            // leave the Text field exactly as it was — see the ApexDoc's fourth outcome.
            if (buyer == null) {
                continue;
            }
            nda.Counterparty_Name__c = truncate(buyer.Name);
        }
    }

    /**
     * `Contact.Name` cut to `Counterparty_Name__c`'s 120-character ceiling.
     *
     * 🔴 `String.abbreviate` IS DELIBERATELY NOT USED. It would append an ellipsis, spending three of
     * the 120 characters to say "this was cut" on a field whose whole job is to be a name that a
     * human reads and that a report groups by. A silent cut keeps the first 120 characters intact.
     *
     * @param name The Contact's compound Name; null-safe.
     * @return The name, cut to 120 characters; null when the input is null.
     */
    private static String truncate(String name) {
        if (name == null) {
            return null;
        }
        return (name.length() <= COUNTERPARTY_NAME_MAX)
            ? name
            : name.substring(0, COUNTERPARTY_NAME_MAX);
    }
}
