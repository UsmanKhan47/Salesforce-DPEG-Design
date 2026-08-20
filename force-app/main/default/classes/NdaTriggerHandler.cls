/**
 * Trigger handler for `NDA__c` — the FIRST one this object has ever had (created 2026-08-20,
 * Tranche 2 Workstream D). Extends the project's `TriggerHandler` base per
 * `.claude/rules/apex-layering-rule.md`, so `NdaTrigger` itself is one line and every context this
 * handler does not override inherits a safe no-op.
 *
 *   before insert -> NdaBuyerStampService.stampBuyerName (in-memory, ZERO DML)
 *   before update -> NdaBuyerStampService.stampBuyerName (in-memory, ZERO DML)
 *
 * That is the whole handler. It is a ROUTER with no rules of its own — the "what counts as a
 * change", the four outcomes and the truncation all live in the service, which is where they belong
 * and where they can be unit-tested without a DML.
 *
 * ── 🔴 WHY A SERVICE RATHER THAN THE LOGIC INLINE HERE ──────────────────────────────────────
 * `BovSubmissionTriggerHandler` and `DispositionOfferTriggerHandler` both set a precedent for
 * keeping TRIVIAL logic in the handler, and that precedent explicitly does NOT cover this: it is
 * conditioned on the logic having *"ZERO inline SOQL"*, and this stamp needs a CONTACT READ.
 * `.claude/rules/apex-layering-rule.md` prohibits SOQL in a TriggerHandler and in a Domain alike, so
 * a Service calling a Selector is the only conforming home. Same split, same reasoning, as
 * `BovSubmissionBrokerStampService` and `DispositionOfferSelectionGuardService`.
 *
 * ── ⚠ THE ACQUISITION HALF OF A DUAL-MODULE OBJECT PASSES THROUGH HERE TOO ──────────────────
 * This handler is invoked for EVERY `NDA__c` save in the org, acquisition NDAs included. It does not
 * filter by record type or by parent lookup, and it must not start doing so — the change-key inside
 * the service is what makes those saves free, and a record-type filter would be inert during the
 * Master-record-type migration window. The blast-radius argument in full is in `NdaTrigger`'s own
 * header; the writer-by-writer table is in `NdaBuyerStampService`'s.
 *
 * ── BUDGET ──────────────────────────────────────────────────────────────────────────────────
 * AT MOST 1 SOQL and EXACTLY 0 DML per chunk, CONSTANT in the number of NDAs. A chunk in which no
 * record changed `Buyer__c` — the overwhelmingly common case — costs nothing at all. Trigger-driven,
 * so `.claude/rules/bulk-test-rule.md`'s 251-record mandate APPLIES; the falsifiers live in
 * `NdaBuyerStampServiceTest`.
 *
 * ── SHARING ─────────────────────────────────────────────────────────────────────────────────
 * `with sharing`, per the project standard. The service declares its own keyword, which this router
 * does not alter.
 *
 * @see force-app/main/default/triggers/NdaTrigger.trigger (the one-line trigger)
 * @see force-app/main/default/classes/NdaBuyerStampService.cls (all the logic)
 * @see force-app/main/default/classes/TriggerHandler.cls (the base)
 */
public with sharing class NdaTriggerHandler extends TriggerHandler {

    /**
     * ⚠ `oldMap` is passed as NULL rather than `this.oldMap`: the platform leaves `Trigger.oldMap`
     * null on insert, and the service's contract documents null-on-insert as the shape it expects
     * (every non-null `Buyer__c` then counts as a change). Stated explicitly because
     * `DispositionOfferTriggerHandler.beforeInsert` makes the same choice for the same reason.
     */
    protected override void beforeInsert() {
        NdaBuyerStampService.stampBuyerName((List<NDA__c>) newList, null);
    }

    protected override void beforeUpdate() {
        NdaBuyerStampService.stampBuyerName(
            (List<NDA__c>) newList,
            (Map<Id, NDA__c>) oldMap
        );
    }
}
